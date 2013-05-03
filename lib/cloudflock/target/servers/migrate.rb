require 'cloudflock/remote/ssh'
require 'thread'
require 'cpe'

# Public: Provides methods to facilitate as many discrete steps of a migration
# between like hosts as possible.  The assumption is made that the destination
# host will be put into rescue mode, or will otherwise be able to recover if
# any files transferred overwrite extant files on the filesystem (e.g. glibc.)
# The steps are as granular as possible to avoid the requirement that every
# step is strictly followed.
#
# Examples
#
#   # Perform setup of source and destination hosts, but don't migrate
#   setup_managed(destination_host)
#   setup_source(source_host)
#
#   # Assume that all setup has been done; migrate the host with no watchdogs
#   migrate_server(source_host, destination_host)
module CloudFlock::Target::Servers::Migrate extend self
  # Internal: location of the directory containing data for exclusions/clean-up
  DATA_LOCATION = File.expand_path('../../servers/data', __FILE__)

  # Public: Monitor for managed cloud scripts to complete.  Return true if they
  # do, false otherwise.
  #
  # host    - SSH object logged in to the destination host.
  # timeout - Fixnum containing the number of seconds to wait. (default: 1200)
  #
  # Returns true or false depending on whether or not manages scripts have
  # finished.
  def setup_managed(host, timeout = 3600)
    i = 0
    finished = false
    managed_check = %w{[ -f  /tmp/rs_managed_cloud_automation_complete ] &&
                       printf 'DONE' || printf 'GOING'}.join(' ')
    while i < timeout && !finished
      i += sleep(60)
      mc_task_status = host.set_timeout(60) do
        host.query("MANAGED_CHECK", managed_check)
      end
      finished = true if mc_task_status == "DONE"
    end

    finished
  end

  # Public: Prepare the destination host for automated migration steps by
  # installing rsync, mounting the primary disk to /mnt/migration_target,
  # installing a temporary ssh public key for root, and backing up the original
  # passwd, shadow and group files (in case of managed migration).
  #
  # host   - SSH object logged in to the destination host.
  # pubkey - String containing the text of the ssh public key to install for
  #          root.
  #
  # Returns nothing.
  def setup_destination(host, pubkey)
    host.set_timeout(300)

    host.puts("mkdir /mnt/migration_target")
    host.prompt

    disk = host.query("DISK_XVDB1", "[ -e /dev/xvdb1 ] && printf 'xvdb1'")
    disk = "sda1" if disk.empty?
    host.puts("mount -o acl /dev/#{disk} /mnt/migration_target")
    host.prompt

    preserve_files = ["passwd", "shadow", "group"]
    path = "/mnt/migration_target/etc"
    preserve_files.each do |file|
      copy_command = "[ -f #{path}/migration.#{file} ] || /bin/cp -an " +
                     "#{path}/#{file} #{path}/migration.#{file}"
      host.puts(copy_command)
      host.prompt
    end

    package_manager = host.query("MANAGER", "which {yum,apt-get} 2>/dev/null")
    host.set_timeout(120) do
      host.puts("#{package_manager} install rsync -y")
      host.prompt
    end

    host.puts("rsync")
    host.expect(/rsync error/)
    host.prompt

    ssh_key = "mkdir $HOME/.ssh; chmod 0700 $HOME/.ssh; printf " +
              "'#{pubkey}\\n' >> $HOME/.ssh/authorized_keys"
    host.puts(ssh_key)
    host.prompt
  end

  # Public: Prepare the source host for automated migration by populating the
  # exclusions list in /root/.rackspace/migration_exceptions.txt and creating a
  # temporary ssh public key in /tmp/RACKSPACE_MIGRATION/
  #
  # host       - SSH object logged in to the source host.
  # exclusions - String containing the exclusions list for the source host.
  #
  # Returns a String object containing the host's new ssh public key.
  def setup_source(host, exclusions)
    host.puts("mkdir /root/.rackspace")
    host.prompt

    exclude = "cat <<EOF > /root/.rackspace/migration_exceptions.txt" +
              "\n#{exclusions}\nEOF"
    host.puts(exclude)
    host.prompt

    ssh_keygen = %w{mkdir /tmp/RACKSPACE_MIGRATION && ssh-keygen -b 2048 -q -t
                    rsa -f /tmp/RACKSPACE_MIGRATION/migration_id_rsa -P
                    ''}.join(' ')
    host.puts(ssh_keygen)
    host.prompt

    host.query("PUBKEY", "cat /tmp/RACKSPACE_MIGRATION/migration_id_rsa.pub")
  end

  # Public: Check for connectivity over RFC 1918 networks for a pair of hosts.
  # Return the first network address which offers connectivity.
  #
  # source_host      - SSH object logged in to the source host.
  # destination_host - SSH object logged in to the destination host.
  #
  # Returns a String containing an IP address if connectivity is verified.
  # Returns nil otherwise.
  def check_servicenet(source_host, destination_host)
    keygen_command = "ssh-keygen -lf /etc/ssh/ssh_host_rsa_key.pub"
    destination_rsa = destination_host.query("RSA_FINGERPRINT", keygen_command)
    destination_rsa.gsub!(/^[^ ]* /, '').gsub!(/ .*/, '')

    ip_discovery = %w{ifconfig|grep 'inet addr:10\.' | sed
                      's/.*addr:\([^ ]*\) .*/\1/g' | xargs}.join(' ')
    ips = destination_host.query("IFCONFIG", ip_discovery)

    ips.split(/\s+/).each do |addr|
      # Change NumberOfPasswordPrompts to 0, and StrictHostKeyChecking to yes
      ssh_arguments = CloudFlock::Remote::SSH::SSH_ARGUMENTS.gsub(/1/, '0')
      ssh_arguments.gsub!("-o StrictHostKeyChecking=no", '')
      source_host.puts("ssh #{ssh_arguments} #{addr}")
      remote_rsa = source_host.set_timeout(30) do
        source_host.expect(/^RSA.*$/, true)
      end
      source_host.set_timeout(120) do
        source_host.send("\C-c")
        source_host.prompt
      end
      next if remote_rsa.nil?

      return addr unless remote_rsa.to_s.match(destination_rsa).nil?
    end

    nil
  end

  # Public: Commense migration by launching 2 rsync processes: the first to
  # move the bulk of the data in question and the second to provide a delta,
  # ensuring a more complete dataset transfer.
  #
  # source_host      - SSH object logged in to the source host.
  # destination_host - SSH object logged in to the destination host.
  # args             - Hash containing additional parameters for operation.
  #                    (default: {}):
  #                    :target_addr - String containing the address to use when
  #                                   communicating with the destination host.
  #                    :rsync       - String containing path to rsync binary on
  #                                   the source machine.  If this is nil, copy
  #                                   rsync from the destination machine to
  #                                   /root/.rackspace/ for the purposes of
  #                                   carrying out the migration.
  #                                   (default: nil)
  #
  # Returns a Thread object encapsulating the migration.
  # Raises ArgumentError if args[:target_addr] is not set.
  def migrate_server(source_host, args)
    if args[:target_addr].nil?
      raise ArgumentError, "Need target address for server"
    end

    # If we lack rsync, fetch it from the destination server
    unless args[:rsync]
      source_host.puts("mkdir /root/.rackspace")
      source_host.prompt

      rsync_install = "scp #{CloudFlock::Remote::SSH::SSH_ARGUMENTS} -i " +
                      "/tmp/RACKSPACE_MIGRATION/migration_id_rsa " +
                      "root@#{args[:host]}:/usr/bin/rsync " +
                      "/root/.rackspace/rsync"
      source_host.puts(rsync_install)
      source_host.prompt
      args[:rsync] = "/root/.rackspace/rsync"
    end

    2.times do
      finished = false
      until finished
        source_host.send("\C-c")
        sleep 45
        source_host.puts
        while source_host.prompt(true)
        end

        finished = migration_watcher(source_host, args)
      end

      sed_command = 'sed -i "s/\/var\/log//g" ' + 
                    '/root/.rackspace/migration_exceptions.txt'
      source_host.puts(sed_command)
      source_host.prompt
    end
  end

  # Internal: Execute rsync and return true if everything appears to have completed successfully
  #
  # source_host      - SSH object logged in to the source host.
  # args             - Hash containing additional parameters for operation.
  #                    Expected parameters are:
  #                    :target_addr - String containing the address to use when
  #                                   communicating with the destination host.
  #                    :rsync       - String containing path to rsync binary on
  #                                   the source machine.  If this is nil, copy
  #                                   rsync from the destination machine to
  #                                   /root/.rackspace/ for the purposes of
  #                                   carrying out the migration.
  #                                   (default: nil)
  #                    :timeout     - Fixnum containing the number of seconds
  #                                   to wait before reporting failure/hung
  #                                   rsync process.  If this is set to -1, a
  #                                   failure will never be reported--use
  #                                   Watchdogs in this case to prevent
  #                                   indefinite migrations.  (default: 14400)
  #
  # Returns true if rsync finishes.
  # Returns false if rsync does not complete within timeout.
  def migration_watcher(source_host, args)
    rsync_command = "#{args[:rsync]} -azP -e 'ssh " +
                    "#{CloudFlock::Remote::SSH::SSH_ARGUMENTS} -i " +
                    "/tmp/RACKSPACE_MIGRATION/migration_id_rsa' " +
                    "--exclude-from='/root/.rackspace/" +
                    "migration_exceptions.txt' / " +
                    "root@#{args[:target_addr]}:/mnt/migration_target"
    source_host.puts(rsync_command)

    source_host.set_timeout(60)
    if(args[:timeout] >= 0)
      i = args[:timeout]/60 + 1
    else
      i = -1
    end

    begin
      source_host.prompt
    rescue Timeout::Error
      i -= 1
      retry unless i == 0
      return false
    end

    true
  end

  # Public: Build exclusions list from generic and targeted exclusions
  # definitions per CPE.
  #
  # cpe - CPE object to use in generating the default exclusions list.
  #
  # Returns a String containing the exclusions list generated.
  def build_default_exclusions(cpe)
    exclude = ""
    exclude << File.open("#{DATA_LOCATION}/exceptions/base.txt", "r").read
    vendor = cpe.vendor.downcase
    version = cpe.version.to_s.downcase
    path = "#{DATA_LOCATION}/exceptions/platform/"

    if File.exists?("#{path}#{vendor}.txt")
      exclude << File.open("#{path}#{vendor}.txt", "r").read
    end
    if File.exists?("#{path}#{vendor}_#{version}.txt")
      exclude << File.open("#{path}#{vendor}_#{version}.txt", "r").read
    end

    exclude
  end

  # Public: Restore the rackconnect user in order to maintain Rack Connect
  # functionality for a host on which Rack Connect automation has previously
  # run.
  #
  # destination_host - SSH object logged in to the destination host.
  #
  # Returns true if the rackconnect user is restored, false otherwise.
  def cleanup_rackconnect_destination(destination_host)
    return false unless restore_user(destination_host, "rackconnect")

    sudoers = "cat <<EOF >> /etc/sudoers\n\nrackconnect ALL=(ALL) NOPASSWD: " +
              "ALL\nDefaults:rackconnect !requiretty\nEOF"

    destination_host.puts(sudoers)
    destination_host.prompt

    true
  end

  # Public: Restore the rack user in order to maintain access on hosts which
  # belong to a Managed Cloud account, on which Managed Cloud automation has
  # already run.
  #
  # destination_host - SSH object logged in to the destination host.
  #
  # Returns true if the rack user is restored, false otherwise.
  def cleanup_manage_destination(destination_host)
    return false unless restore_user(destination_host, "rack")

    sudoers = "cat <<EOF >> /etc/sudoers\n\nrack ALL=(ALL) NOPASSWD: ALL\nEOF"
    destination_host.puts(sudoers)
    destination_host.prompt

    true
  end

  # Internal: Create user and restore entries from backup passwd and shadow
  # files.
  #
  # destination_host - SSH object logged in to the host on which to restore a
  #                    user.
  # username         - String containing the user to restore.
  #
  # Returns true if success, false otherwise.
  def restore_user(destination_host, username)
    username.strip!
    sanity_check = "(grep '^#{username}:' /etc/migration.passwd && grep " +
                   "'^#{username}:' /etc/migration.shadow) >/dev/null " +
                   "2>/dev/null && printf 'PRESENT'"

    sane = destination_host.query("USER_CHECK", sanity_check)
    return false if sane.empty?

    steps = ["useradd #{username}",
             "chown -R #{username}.#{username} /home/#{username}",
             "sed -i '/^#{username}:.*$/d' /etc/shadow",
             "grep '^#{username}:' /etc/migration.shadow >> /etc/shadow"]
    steps.each do |step|
      destination_host.puts(step)
      destination_host.prompt
    end

    true
  end

  # Public: Perform post-migration clean up of a destination host.  Base
  # clean up off of cleanup scripts located at data/cleanup/.
  #
  # destination_host - SSH object logged in to the destination host.
  # cpe              - CPE object describing the platform in question.
  #
  # Returns nothing.
  def clean_destination(destination_host, cpe)
    clean_pre = ""
    clean_chroot = ""
    clean_post = ""

    vendor = cpe.vendor.downcase
    version = cpe.version.to_s.downcase

    # Build pre-chroot, chroot and post-chroot scripts
    ["pre", "chroot", "post"].each do |name|
      clean = eval("clean_#{name}")
      clean << "#/bin/bash\n\n"
      path = "#{DATA_LOCATION}/post-migration/#{name}"

      if File.exists? "#{path}/base.txt"
        clean << File.open("#{path}/base.txt", "r").read
      end
      if File.exists? "#{path}/platform/#{vendor}.txt"
        clean << File.open("#{path}/platform/#{vendor}.txt", "r").read
      end
      if File.exists? "#{path}/platform/#{vendor}_#{version}.txt"
        clean << File.open("#{path}/platform/#{vendor}_#{version}.txt", "r").read
      end
    end

    pre_command = "cat <<EOF > /root/migration_clean_pre.sh\n" +
                  "#{clean_pre.gsub(/\$/, '\\$')}\nEOF"
    chroot_command = "cat <<EOF > /mnt/migration_target/root/migration_" +
                     "clean_chroot.sh\n#{clean_chroot.gsub(/\$/, '\\$')}\nEOF"
    post_command = "cat <<EOF > /root/migration_clean_post.sh\n" +
                   "#{clean_post.gsub(/\$/, '\\$')}\nEOF"
    [pre_command, chroot_command, post_command].each do |command|
      destination_host.puts(command)
      destination_host.prompt
    end

    # Perform pre-chroot steps
    long_run(destination_host, "/bin/bash /root/migration_clean_pre.sh")

    # Chroot into the new environment
    destination_host.puts("chroot /mnt/migration_target /bin/bash")

    # Set host prompt, etc
    destination_host.puts("export PS1='#{CloudFlock::Remote::SSH::PROMPT} '")
    destination_host.get_root('')

    # Perform chroot steps
    long_run(destination_host, "/bin/bash /root/migration_clean_chroot.sh")
    destination_host.puts("rm -f /root/migration_clean_chroot.sh")
    destination_host.prompt

    # Add Rack Connect and Managed users
    cleanup_manage_destination(destination_host)
    cleanup_rackconnect_destination(destination_host)

    destination_host.puts("exit")
    destination_host.prompt

    # Perform post-chroot steps
    long_run(destination_host, "/bin/bash /root/migration_clean_post.sh")
  end

  # Internal: Insure that new output is being produced by a running process
  # which is expected to run over an indeterminate amount of time to catch
  # hanging processes, but not punish properly running ones.
  #
  # host    - SSH object pointing to the host in question.
  # command - String containing the command to be executed.
  # timeout - Fixnum containing the maximum number of seconds for new output
  #           to be produced. (default: 30)
  #
  # Returns nothing.
  # Raises any exception passed other than Timeout::Error (IE ProcessError).
  def long_run(host, command, timeout=30)
    unless host.kind_of?(CloudFlock::Remote::SSH)
      raise ArgumentError, "Host must be a SSH Object"
    end
    unless command.kind_of?(String)
      raise ArgumentError, "Command must be a String"
    end

    last_line = ''
    newline_count = 0
    fail_count = 0
    fail_max = 10

    host.puts(command.strip)
    host.set_timeout(timeout) do
      begin
        host.prompt
      rescue Timeout::Error
        lines = host.buffer.split(/\n/)
        current_line = lines[-1]
        current_count = lines.length

        if last_line == current_line && newline_count == current_count
          fail_count += 1
          raise LongRunFailed if fail_count == fail_max
        else
          fail_count = 0
          last_line = current_line
          newline_count = current_count
        end

        retry
      end
    end
  end
end
