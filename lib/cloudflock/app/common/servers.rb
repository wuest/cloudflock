require 'console-glitter'
require 'cloudflock/app'
require 'cloudflock/remote/ssh'
require 'cloudflock/app/common/rackspace'
require 'cloudflock/app/common/exclusions'
require 'cloudflock/app/common/cleanup'

module CloudFlock; module App
  # Public: The Common module provides common methods for CLI interaction
  # pertaining to interaction with remote (Unix) servers and the Rackspace API.
  module Common
    include Rackspace
    include ConsoleGlitter
    include CloudFlock::App
    include CloudFlock::Remote

    # Path to the base directory in which any CloudFlock files will be stored.
    DATA_DIR      = '/root/.cloudflock'

    # Path to the file in which paths excluded from being migrated are stored.
    EXCLUSIONS    = "#{DATA_DIR}/migration_exclusions"

    # Path to the private key to be generated for migration.
    PRIVATE_KEY   = "#{DATA_DIR}/migration_id_rsa"

    # Path to the public key corresponding to PRIVATE_KEY.
    PUBLIC_KEY    = "#{PRIVATE_KEY}.pub"

    # Path to the default path for root partition of the destination host to be
    # mounted.
    MOUNT_POINT   = '/mnt/migration_target'

    # Commonly used arguments to ssh.
    SSH_ARGUMENTS = CloudFlock::Remote::SSH::SSH_ARGUMENTS

    # Public: Collect information about the source server to be migrated.
    #
    # host - Hash containing any options which may pertain to the host.
    #
    # Returns a Hash containing information pertinent to logging in to a host.
    def define_source(host)
      define_host(host, 'Source')
    end

    # Public: Collect information about the destination server to which data
    # will be migrated.
    #
    # host - Hash containing any options which may pertain to the host.
    #
    # Returns a Hash containing information pertinent to logging in to a host.
    def define_destination(host)
      host.select! { |key| /dest_/.match(key) }
      host = host.reduce({}) do |c, e|
        key = e[0].to_s
        c[key.gsub(/dest_/, '').to_sym] = e[1]
        c
      end
      define_host(host, 'Destination')
    end

    # Public: Collect information about a named server to be migrated.
    #
    # opts - Hash containing any applicable options mappings for the server in
    #        question.
    # name - String containing the name/description for the host.
    #
    # Returns a Hash containing information pertinent to logging in to a host.
    def define_host(host, name)
      host = host.dup
      check_option(host, :hostname, "#{name} host")
      check_option(host, :port, "#{name} SSH port", default_answer: '22')
      check_option(host, :username, "#{name} username", default_answer: 'root')
      check_option(host, :password, "#{name} password",
                   default_answer: '', allow_empty: true)

      key_path = File.join(Dir.home, '.ssh', 'id_rsa')
      key_path = '' unless File.exists?(key_path)
      check_option(host, :ssh_key, "#{name} SSH Key",
                   default_answer: key_path, allow_empty: true)

      # Using sudo is only applicable if the user isn't root
      host[:sudo] = false if host[:username] == 'root'
      check_option(host, :sudo, 'Use sudo? (Y/N)', default_answer: 'Y')

      # If non-root and using su, the root password is needed
      if host[:username] == 'root' || host[:sudo]
        host[:root_password] = host[:password]
      else
        check_option(host, :root_password, 'Password for root')
      end

      host
    end

    # Public: Have the user select from a list of available images to provision
    # a new host.
    #
    # api         - Authenticated Fog API instance.
    # profile     - Profile of the source host.
    # constrained - Whether the list should be constrained to flavors which
    #               appear to be appropriate. (default: true)
    #
    # Returns a String.
    def define_compute_image(api, profile, constrained = true)
      image_list = filter_compute_images(api, profile, constrained)
      if image_list.length == 1
        puts "Suggested image: #{UI.blue { image_list.first[:name] }}"
        if UI.prompt_yn('Use this image? (Y/N)', default_answer: 'Y')
          return image_list.first[:id]
        end
      elsif image_list.length > 1
        puts generate_selection_table(image_list, constrained)

        image = UI.prompt('Image to provision', valid_answers: [/^\d+$/, 'A'])
        return image_list[image.to_i][:id] unless /A/.match(image)
      end

      define_compute_image(api, profile, false)
    end

    # Public: Filter available images to those expected to be appropriate for
    # a given amount of resource usage.
    #
    # api         - Authenticated Fog API instance.
    # profile     - Profile of the source host.
    # constrained - Whether the list should be constrained to images which
    #               appear to be appropriate.
    #
    # Returns an Array of Hashes mapping :name to the image name and :id to the
    # image's internal id.
    def filter_compute_images(api, profile, constrained)
      image_list = api.images.to_a
      if constrained
        cpe = profile.cpe
        search = [cpe.vendor, cpe.version]
        search.map! { |s| Regexp.new(s, Regexp::IGNORECASE) }

        image_list.select! do |image|
          search.reduce(true) { |c,e| e.match(image.name) && c }
        end
      end
      image_list.map! { |image| { name: image.name, id: image.id } }
    rescue Excon::Errors::Timeout
      retry if retry_prompt('Unable to fetch a list of available images.')
      raise
    end

    # Public: Have the user select from a list of available flavors to
    # provision a new host.
    #
    # api         - Authenticated Fog API instance.
    # profile     - Profile of the source host.
    # constrained - Whether the list should be constrained to flavors which
    #               appear to be appropriate. (default: true)
    #
    # Returns a String.
    def define_compute_flavor(api, profile, constrained = true)
      flavor_list = filter_compute_flavors(api, profile, constrained)

      puts "Suggested flavor: #{UI.blue { flavor_list.first[:name] }}"
      if UI.prompt_yn('Use this flavor? (Y/N)', default_answer: 'Y')
        return flavor_list.first[:id]
      end

      puts generate_selection_table(flavor_list, constrained)
      flavor = UI.prompt('Flavor to provision', valid_answers: [/^\d+$/, 'A'])
      return flavor_list[flavor.to_i][:id] unless /A/.match(flavor)

      define_compute_flavor(api, profile, false)
    end

    # Public: Filter available flavors to those expected to be appropriate for
    # a given amount of resource usage.
    #
    # api         - Authenticated Fog API instance.
    # profile     - Profile of the source host.
    # constrained - Whether the list should be constrained to flavors which
    #               appear to be appropriate.
    #
    # Returns an Array of Hashes mapping :name to the flavor name and :id to
    # the flavor's internal id.
    def filter_compute_flavors(api, profile, constrained)
      flavor_list = api.flavors.to_a
      if constrained
        hdd = profile.select_entries(/Storage/, /Usage/)
        ram = profile.select_entries(/Memory/, /Used/)
        hdd = hdd.first.to_i
        ram = ram.first.to_i

        flavor_list.select! { |flavor| flavor.disk > hdd && flavor.ram > ram }
      end
      flavor_list.map! { |flavor| { name: flavor.name, id: flavor.id } }
    end

    # Public: Prompt user for the name of a new host to be created, presenting
    # the hostname of the source host as a default option.
    #
    # profile - Profile of the source host.
    #
    # Returns a String.
    def define_compute_name(profile)
      name = profile.select_entries(/System/, 'Hostname').join

      new_name = UI.prompt("Name", default_answer: name, allow_empty: false)
      new_name.gsub(/[^a-zA-Z0-9_-]/, '-')
    end

    # Public: Create a printable table with options to be presented to a user.
    #
    # options     - Array of Hashes containing columns to be desplayed, with
    #               the following keys:
    #               :selection_id - ID for the user to select the option.
    #               :name         - String containing the option's name.
    # constrained - Whether the table is constrained (and a "View All" option
    #               is appropriate).
    #
    # Returns a String.
    def generate_selection_table(options, constrained)
      options = options.each_with_index.map do |option, index|
        { selection_id: index.to_s, name: option[:name] }
      end
      options << { selection_id: 'A', name: 'View All' } if constrained
      labels = { selection_id: 'ID', name: 'Name' }
      UI.build_grid(options, labels)
    end

    # Public: Create a new compute instance via API.
    #
    # api          - Authenticated Fog API instance.
    # managed      - Whether the instance is expected to be managed (if
    #                Rackspace public cloud).
    # compute_spec - Hash containing parameters to pass via the API call.
    #
    # Returns a Hash with information necessary to log in to the new host.
    def provision_compute(api, managed, compute_spec)
      host = UI.spinner("Waiting for #{compute_spec[:name]} to provision") do
        host = api.servers.create(compute_spec)
        host.wait_for { ready? }
        host
      end
      managed_wait(host) if managed
      rescue_compute(host)

      { username: 'root', port: '22' }.merge(get_host_details(host))
    rescue Fog::Errors::TimeoutError, Excon::Errors::Timeout
      retry if retry_prompt('Provisioning failed.')
      raise
    end

    # Public: Wait for a Rackspace Cloud instance with Managed service level to
    # finish post-provisioning automation.
    #
    # host - Fog::Compute instance.
    #
    # Returns nothing.
    def managed_wait(host)
      finished = '/tmp/rs_managed_cloud_automation_complete'
      connect = { username: 'root', port: '22' }.merge(get_host_details(host))

      ssh = ssh_connect(connect)
      UI.spinner('Waiting for managed cloud automation to complete') do
        ssh.as_root("while [ ! -f #{finished} ]; do sleep 5; done", 3600)
      end
    end

    # Public: Get details for a Fog::Compute instance.
    #
    # host - Fog::Compute instance.
    #
    # Returns a Hash containing the host's address and root password.
    def get_host_details(host)
      { hostname: host.ipv4_address,
        password: host.password,
        root_password: host.password }
    end

    # Public: Bring a host into Rescue mode.
    #
    # host - Fog::Compute instance.
    #
    # Returns nothing.
    def rescue_compute(host)
      host.rescue
      begin
        UI.spinner("Waiting for Rescue Mode (password: #{host.password})") do
          host.wait_for { state == 'RESCUE' }
        end
      rescue Fog::Errors::TimeoutError
        retry if retry_prompt('Timeout exceeded waiting for the host.')

        host.destroy
        raise
      end
    rescue Excon::Errors::Timeout
      retry if retry_prompt('API timed out waiting for server status update.')
    end

    # Public: Connect to a host via SSH, automatically retrying a set number of
    # times, and prompting whether to continue trying beyond that.
    #
    # host     - Hash containing information about the host.  Defaults are
    #            defined in the CloudFlock::Remote::SSH Class.
    # attempts - Number of times to retry connecting before alerting the user
    #            to failures and asking whether to continue. (Default: 5)
    #
    # Returns an SSH Object.
    def ssh_connect(host, attempts = 5)
      attempt = 0

      UI.spinner("Logging in to #{host[:hostname]}") do
        begin
          SSH.new(host)
        rescue Net::SSH::Disconnect
          sleep 10
          attempt += 1
          retry if attempt < 5
        end
      end
    rescue Net::SSH::Disconnect
      retry if retry_prompt('Unable to establish a connection.')
      raise
    end

    # Public: Perform the final preperatory steps necessary as well as the
    # migration.
    #
    # source_shell - SSH object logged in to the source host.
    # dest_shell   - SSH object logged in to the destination host.
    # exclusions   - String containing the exclusions list for the migration.
    #
    # Returns a String containing the host's new ssh public key.
    def migrate_server(source_shell, dest_shell, exclusions)
      pubkey = UI.spinner('Generating a keypair for the source environment') do
        generate_keypair(source_shell)
      end

      UI.spinner('Preparing the destination environment') do
        setup_destination(dest_shell, pubkey)
      end

      rsync = UI.spinner('Preparing the source environment') do
        location = setup_source(source_shell, exclusions)
        if location.empty?
          location = transfer_rsync(source_shell, dest_shell)
        end

        location
      end

      dest_address = UI.spinner('Checking for ServiceNet') do
        determine_target_address(source_shell, dest_shell)
      end

      rsync = "#{rsync} -azP -e 'ssh #{SSH_ARGUMENTS} -i #{PRIVATE_KEY}' " +
              "--exclude-from='#{EXCLUSIONS}' / #{dest_address}:#{MOUNT_POINT}"

      UI.spinner('Performing rsync migration') do
        2.times do
          # TODO: this dies in exceptional cases
          source_shell.as_root(rsync, 7200)
          source_shell.as_root("sed -i 's/\/var\/log//g' #{EXCLUSIONS}")
        end
      end
    end

    # Public: Create a temporary ssh key to be used for passwordless access to
    # the destination host.
    #
    # shell - SSH object logged in to the source host.
    #
    # Returns a String containing the host's new ssh public key.
    def generate_keypair(shell)
      shell.as_root("mkdir #{DATA_DIR}")
      shell.as_root("ssh-keygen -b 4096 -q -t rsa -f #{PRIVATE_KEY} -P ''")
      shell.as_root("cat #{PUBLIC_KEY}")
    end

    # Public: Prepare the source host for migration by populating the
    # exclusions list in the file located at EXCLUSIONS and determining the
    # location of rsync on the system.
    #
    # shell      - SSH object logged in to the source host.
    # exclusions - String containing the exclusions list for the source host.
    #
    # Returns a String containing path to rsync on the host if present.
    def setup_source(shell, exclusions)
      shell.as_root("cat <<EOF> #{EXCLUSIONS}\n#{exclusions}\nEOF")
      shell.as_root('which rsync 2>/dev/null')
    end

    # Public: Transfer rsync from the destination host to the source host to
    # facilitate the migration.
    #
    # source_shell - SSH object logged in to the source host.
    # dest_shell   - SSH object logged in to the source host.
    #
    # Raises NoRsyncAvailable if rsync doesn't exist on the destination host.
    #
    # Returns a String.
    def transfer_rsync(source_shell, dest_shell)
      host     = dest_shell.hostname
      location = dest_shell.as_root('which rsync')
      raise(NoRsyncAvailable, Errstr::NO_RSYNC) if location.empty?

      scp = "scp #{SSH_ARGUMENTS} -i #{PRIVATE_KEY} #{host}:#{location} " +
            "#{DATA_DIR}/"

      source_shell.as_root(scp)
      "#{DATA_DIR}/rsync"
    end

    # Public: Prepare the destination host for migration by verifying that
    # rsync is present, mounting the primary disk to /mnt/migration_target,
    # installing a temporary ssh public key for root, and backing up the
    # original passwd, shadow and group files.
    #
    # shell  - SSH object logged in to the destination host.
    # pubkey - String containing the text of the ssh public key to install for
    #          root.
    #
    # Returns nothing.
    def setup_destination(shell, pubkey)
      preserve_files = ['passwd', 'shadow', 'group']
      path = "#{MOUNT_POINT}/etc"

      # TODO: Dynamic mountpoint/block device support
      # Presently mount point and block device are hard-coded.  This will be
      # changed in a future release.
      shell.as_root("mkdir -p #{MOUNT_POINT}")
      shell.as_root("mount -o acl /dev/xvdb1 #{MOUNT_POINT}")

      preserve_files.each do |file|
        original = "#{path}/#{file}"
        backup   = "#{original}.migration"
        shell.as_root("[ -f #{backup} ] || /bin/cp -a #{original} #{backup}")
      end

      # TODO: Better distro support
      # Only Debian- and RedHat-based Unix hosts support automatic rsync
      # installation at this time.  This will be fixed in a future release.
      unless /rsync error/.match(shell.as_root('rsync'))
        package_manager = shell.as_root('which {yum,apt-get} 2>/dev/null')
        raise NoRsyncAvailable if package_manager.empty?
        shell.as_root("#{package_manager} install rsync -y", 300)
      end

      ssh_key = "mkdir $HOME/.ssh; chmod 0700 $HOME/.ssh; printf " +
                "'#{pubkey}\\n' >> $HOME/.ssh/authorized_keys"
      shell.as_root(ssh_key)
    end

    # Public: Determine what address should be used when connecting from source
    # to destination for the purpose of a migration.  Prefer RFC1918 networks.
    #
    # source_shell - SSH object logged in to the source host.
    # dest_shell   - SSH object logged in to the destination host.
    #
    # Returns a String containing the appropriate address.
    def determine_target_address(source_shell, dest_shell)
      hostname = dest_shell.hostname
      host_key = check_hostkey(dest_shell, '127.0.0.1')

      ips = dest_shell.query('ifconfig')
      ips = ips.lines.select { |line| /inet[^6]/.match(line) }

      ips.map! { |line| line.strip.split(/\s+/)[1] }
      ips.map! { |ip| ip.gsub(/[^0-9\.]/, '') }

      ips.select! { |ip| check_hostkey(source_shell, ip) == host_key }
      return ips.last if ips.any?

      hostname
    end

    # Public: Determine the ssh hostkey visible to a given host from an IP.
    #
    # shell - SSH object logged in to a host.
    # ip    - String containing an ip (or hostname) for which to get a key.
    #
    # Returns a String containing the key given by the host, or false if none
    # given.
    def check_hostkey(shell, ip)
      ssh_cmd  = 'ssh -o UserKnownHostsFile=/dev/null ' \
                 '-o NumberOfPasswordPrompts=0'

      hostkey = shell.query("#{ssh_cmd} #{ip}", 15, true)
      key = hostkey.lines.select { |line| /fingerprint is/.match(line) }
      key.first.to_s.strip.gsub(/.*fingerprint is /, '').gsub(/\.$/, '')
    end

    # Public: Perform post-migration cleanup tasks.
    #
    # shell   - SSH object logged in to the target host.
    # profile - CPE describing the platform in question.
    #
    # Returns nothing.
    def cleanup_destination(shell, profile)
      UI.spinner('Performing post-migration cleanup') do
        cleanup        = Cleanup.new(profile)
        chroot_command = "chroot #{MOUNT_POINT} /bin/sh -C " \
                         "#{DATA_DIR}/chroot.sh"

        restore_rackspace_users(cleanup)

        shell.as_root("mkdir #{DATA_DIR}")
        shell.as_root("cat <<EOF> #{DATA_DIR}/pre.sh\n#{cleanup.pre_s}\nEOF")
        shell.as_root("cat <<EOF> #{DATA_DIR}/post.sh\n#{cleanup.post_s}\nEOF")

        chroot = "cat <<EOF> #{MOUNT_POINT}#{DATA_DIR}/chroot.sh\n" \
                 "#{cleanup.chroot_s}\nEOF"
        shell.as_root("mkdir -p #{MOUNT_POINT}#{DATA_DIR}")
        shell.as_root(chroot)

        shell.as_root("/bin/sh #{DATA_DIR}/pre.sh", 0)
        shell.as_root(chroot_command, 0)
        shell.as_root("/bin/sh #{DATA_DIR}/post.sh", 0)

        cleanup_rackspace_server(shell)
      end
    end

    # Public: Restore any users added by Rackspace automation in order to
    # maintain access on hosts which are meant to be managed by Rackspace.
    #
    # cleanup - Cleanup object to which to add chroot tasks.
    #
    # Returns nothing.
    def restore_rackspace_users(cleanup)
      ['rack', 'rackconnect'].each do |user|
        check_user = "grep '^#{user}:' /etc/passwd.migration"
        cleanup.chroot_step("#{check_user} \&\& useradd #{user}")
      end
    end

    # Public: Restore any users added by Rackspace automation in order to
    # maintain access on hosts which are meant to be managed by Rackspace.
    #
    # shell   - SSH object logged in to the target host.
    #
    # Returns nothing.
    def cleanup_rackspace_server(shell)
      if restore_user(shell, 'rackconnect')
        sudoers         = "rackconnect ALL=(ALL) NOPASSWD: ALL\n" \
                          "Defaults:rackconnect !requiretty"
        sudoers_command = "cat <<EOF >> #{MOUNT_POINT}/etc/sudoers\n\n" \
                          "#{sudoers}\nEOF"

        shell.as_root(sudoers_command)
      end

      if restore_user(shell, 'rack')
        sudoers         = "rack ALL=(ALL) NOPASSWD: ALL"
        sudoers_command = "cat <<EOF >> #{MOUNT_POINT}/etc/sudoers\n\n" \
                          "#{sudoers}\nEOF"
        shell.as_root(sudoers_command)
      end
    end

    # Public: If a given user had previously existed, create that user in the
    # current environment and copy password hash from a backup copy of
    # /etc/shadow.
    #
    # shell - SSH instance logged in to the target host.
    # user  - String containing the username to restore.
    #
    # Returns true if the user was successfully restored, false otherwise.
    def restore_user(shell, user)
      passwd_path = "#{MOUNT_POINT}/etc/passwd"
      shadow_path = "#{MOUNT_POINT}/etc/shadow"

      present = ['passwd', 'shadow'].map do |file|
        path = "#{MOUNT_POINT}/etc/#{file}.migration"
        shell.as_root("grep '^#{user}:' #{path}")
      end
      return false if present.include?('')

      passwd, shadow = present
      uid, gid       = passwd.split(/:/)[2..3]

      steps = ["chown -R #{uid}.#{gid} #{MOUNT_POINT}/home/#{user}",
               "sed -i '/^#{user}:.*$/d' #{shadow_path}",
               "printf '#{shadow}\\n' >> #{shadow_path}"]
      steps.each { |step| shell.as_root(step) }

      true
    end

    # Public: Perform post-migration IP remediation in configuration files.
    #
    # shell   - SSH object logged in to the target host.
    # profile - Profile containing IPs gathered from the source host.
    #
    # Returns nothing.
    def configure_ips(shell, profile)
      destination_profile = CloudFlock::Task::ServerProfile.new(shell)
      source_ips          = profile.select_entries(/IP Usage/, /./)
      destination_ips     = destination_profile.select_entries(/IP Usage/, /./)
      target_directories  = ['/etc']

      puts "Source IPs: #{source_ips.join(', ')} "
      if UI.prompt_yn('Edit IP list? (Y/N)', default_answer: 'N')
        source_ips = edit_ip_list(source_ips)
      end

      puts 'By default only config files under /etc will be remediated.  '
      if UI.prompt_yn('Edit remediation targets? (Y/N)', default_answer: 'N')
        target_directories = edit_directory_list(target_directories)
      end

      puts "Destination IPs: #{destination_ips.join(', ')}"
      source_ips.each { |ip| remediate_ip(shell, ip, target_directories) }
    end

    def remediate_ip(shell, ip, target_directories)
      replace = UI.prompt("Replacement for #{ip}", allow_empty: true).strip
      return if replace.empty?

      sed = "sed -i 's/#{ip}/#{replace}/g' {} \\;"
      UI.spinner("Remediating IP: #{ip}") do
        target_directories.each do |dir|
          shell.as_root("find #{MOUNT_POINT}#{dir} -type f -exec #{sed}", 7200)
        end
      end
    end

    # Public: Display a failure message to the user and prompt whether to
    # retry.
    #
    # message - String containing a failure message.
    #
    # Returns true or false indicating whether the user wishes to retry.
    def retry_prompt(message)
      error = UI.red { "#{message}  Try again? (Y/N)" }
      UI.prompt_yn(error, default_answer: 'Y')
    end
  end
end; end
