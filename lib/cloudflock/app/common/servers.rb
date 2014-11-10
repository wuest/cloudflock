require 'socket'
require 'console-glitter'
require 'cloudflock/app'
require 'cloudflock/remote/ssh'
require 'cloudflock/app/common/rackspace'
require 'cloudflock/app/common/exclusions'
require 'cloudflock/app/common/watchdogs'
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
      check_option_pw(host, :password, "#{name} password",
                      default_answer: '', allow_empty: true)

      key_path = File.join(Dir.home, '.ssh', 'id_rsa')
      key_path = '' unless File.exists?(key_path)
      check_option_fs(host, :ssh_key, "#{name} SSH Key",
                      default_answer: key_path, allow_empty: true)

      # Using sudo is only applicable if the user isn't root
      host[:sudo] = false if host[:username] == 'root'
      check_option(host, :sudo, 'Use sudo? (Y/N)', default_answer: 'Y')

      # If non-root and using su, the root password is needed
      if host[:username] == 'root' || host[:sudo]
        host[:root_password] = host[:password]
      else
        check_option_pw(host, :root_password, 'Password for root')
      end

      host
    end

    # Public: Attempt to log in to a source server to be migrated.
    #
    # source_host - Hash containing any options which may pertain to the host.
    #
    # Returns a CloudFlock::Remote::SSH object logged in to a remote host.
    def connect_source(source_host)
      connect_host(source_host, :define_source)
    end

    # Public: Attempt to log in to a destination server to which data will be
    # migrated.
    #
    # dest_host - Hash containing any options which may pertain to the host.
    #
    # Returns a CloudFlock::Remote::SSH object logged in to a remote host.
    def connect_destination(dest_host)
      connect_host(source_host, :define_destination)
    end

    # Public: Attempt to log in to a target host.
    #
    # host          - Hash containing any applicable options mappings for the
    #                 server in question.
    # define_method - Name of the method to call when re-defining host to
    #                 recover from an exception.
    #
    # Returns a CloudFlock::Remote::SSH object logged in to the target host.
    def connect_host(host, define_method)
      UI.spinner("Logging in to #{host[:hostname]}") do
        SSH.new(host)
      end
    rescue CloudFlock::Remote::SSH::InvalidHostname => e
      error = "Cannot look up #{host[:hostname]}"
      retry_exit(e.message, 'Try another host? (Y/N)')

      host = self.send(define_method, (host.merge({hostname: nil})))
      retry
    rescue CloudFlock::Remote::SSH::SSHCannotConnect => e
      retry if retry_prompt(e.message)
      retry_exit('', 'Try another host? (Y/N)')

      host = self.send(define_method, (host.merge({hostname: nil})))
      retry
    rescue Net::SSH::AuthenticationFailed => e
      retry_exit("Cannot log in as #{host[:username]}.")

      options = {username: nil, password: nil}
      host = self.send(define_method, (host.merge(options)))
      retry
    rescue Errno::ECONNREFUSED
      retry_exit("Connection refused from #{host[:hostname]}")
      retry
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
      retry_exit('Unable to fetch a list of available images.')
      retry
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
    rescue Fog::Errors::TimeoutError, Excon::Errors::Timeout
      retry_exit('Unable to fetch flavor list.')
      retry
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
      host = api.servers.create(compute_spec)
      provision_wait(host, compute_spec[:name])
      managed_wait(host) if managed
      rescue_compute(host)

      { username: 'root', port: '22' }.merge(get_host_details(host))
    rescue Fog::Errors::TimeoutError, Excon::Errors::Timeout
      retry if retry_prompt('Provisioning failed.')
      exit
    end

    # Public: Wait for a Rackspace Cloud instance to be provisioned.
    #
    # host - Fog::Compute instance.
    # name - String containing the name of the server.
    #
    # Returns nothing.
    def provision_wait(host, name)
      UI.spinner("Waiting for #{name} to provision") do
        host.wait_for { ready? }
      end
    rescue Fog::Errors::TimeoutError, Excon::Errors::Timeout
      error = UI.red { 'Provisioning is taking an unusually long time.' }

      retry if UI.prompt_yn("#{error}  Continue waiting? (Y/N)",
                            default_answer: 'Y')
      exit
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
    rescue Timeout::Error
      retry if retry_prompt('Managed cloud automation timed out.')
      host.destroy if UI.prompt_yn('Delete newly created host?')

      exit
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
        exit
      end
    rescue Excon::Errors::Timeout
      retry if retry_prompt('API timed out.', 'Continue waiting?')

      exit
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
      retry_exit('Unable to establish a connection.')
      retry
    rescue Errno::ECONNREFUSED
      retry_exit("Connection refused from #{host[:hostname]}")
      retry
    end

    # Public: Get details for a Fog::Compute instance.
    #
    # host - Fog::Compute instance.
    #
    # Returns a Hash containing the host's address and root password.
    def destroy_host(host)
      host.destroy
    rescue Fog::Errors::TimeoutError, Excon::Errors::Timeout
      retry_exit('API Timed out trying to delete the host.')
      retry
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
      pubkey = prepare_source_ssh_keygen(source_shell)
      prepare_source_exclusions(source_shell, exclusions)
      setup_destination(dest_shell, pubkey)
      rsync = prepare_source_rsync(source_shell, dest_shell)
      dest_address = prepare_source_servicenet(source_shell, dest_shell)

      watchdogs = create_watchdogs(source_shell, dest_shell)
      rsync = "#{rsync} -azP -e 'ssh #{SSH_ARGUMENTS} -i #{PRIVATE_KEY}' " +
              "--exclude-from='#{EXCLUSIONS}' / #{dest_address}:#{MOUNT_POINT}"
      rsync_migrate(watchdogs, source_shell, rsync)
      stop_watchdogs(watchdogs)
    end

    # Public: Generate a new ssh keypair to be used for the migration.
    #
    # shell  - SSH object logged in to the source host.
    #
    # Returns a String containing the new public key.
    def prepare_source_ssh_keygen(shell)
      UI.spinner('Generating a keypair for the source environment') do
        generate_keypair(shell)
      end
    rescue Timeout::Error
      retry_exit('Host is taking a long time generating an ssh keypair.')
      retry
    end

    # Public: Generate a new ssh keypair to be used for the migration.
    #
    # shell      - SSH object logged in to the source host.
    # exclusions - String containing the exclusions list for the source host.
    #
    # Returns a String containing the new public key.
    def prepare_source_exclusions(shell, exclusions)
      UI.spinner('Setting up migration exclusions') do
        shell.as_root("cat <<EOF> #{EXCLUSIONS}\n#{exclusions}\nEOF")
      end
    rescue Timeout::Error
      retry_exit('Host is taking a long time to respond.')
      retry
    end

    # Public: Generate a new ssh keypair to be used for the migration.
    #
    # source_shell - SSH object logged in to the source host.
    # dest_shell   - SSH object logged in to the destination host.
    #
    # Returns a String containing the location rsync on the source host.
    def prepare_source_rsync(source_shell, dest_shell)
      UI.spinner('Determining rsync location') do
        location = determine_rsync(source_shell)
        location = transfer_rsync(source_shell, dest_shell) if location.empty?

        location
      end
    rescue Timeout::Error
      retry_exit('Host is taking a long detecting/installing rsync.')
      retry
    end

    # Public: Determine the target IP address to use for rsync.
    #
    # source_shell - SSH object logged in to the source host.
    # dest_shell   - SSH object logged in to the destination host.
    #
    # Returns a String containing the new IP address to use.
    def prepare_source_servicenet(source_shell, dest_shell)
      dest_address = UI.spinner('Checking for ServiceNet') do
        determine_target_address(source_shell, dest_shell)
      end
    rescue Timeout::Error
      retry_exit('Host is taking a long detecting available networks.')
      retry
    end

    def rsync_migrate(watchdogs, shell, rsync)
      UI.spinner('Waiting for all hosts to appear to be in a healthy state') do
        ensure_no_watchdog_alerts(watchdogs)
      end
      UI.spinner('Performing rsync migration') do
        worker = Thread.new do
          rsync_migrate_thread(shell, rsync)
          Thread.current[:complete] = true
        end
        set_watchdog_alerts(watchdogs, worker)
        worker.join
        raise WatchdogAlert unless worker[:complete]
      end
    rescue WatchdogAlert
      retry
    end

    # Public: Wrap performing an rsync migration.
    #
    # shell - SSH object logged in to the source host.
    # rsync - Command to be run on the source host.
    #
    # Returns nothing.
    def rsync_migrate_thread(shell, rsync)
      2.times do
        rsync_migrate_commands(shell, rsync)
      end
      shell.logout!
    rescue Timeout::Error
      retry if retry_prompt('Server sync is taking a very long time')
      exit
    end

    def ensure_no_watchdog_alerts(watchdogs)
      raise WatchdogAlert if watchdogs.map(&:triggered_alarms).flatten.any?
    rescue WatchdogAlert
      sleep 30
      retry
    end

    # Public: Issue an rsync command, keeping track of how many times a timeout
    # has occurred, raising an error past a threshhold of 3 timeouts.
    #
    # shell   - SSH object logged in to the source host.
    # rsync   - Rsync command to be run on the source host.
    # timeout - Number of times the timeout has been reached. (default: 0)
    #
    # Returns nothing.
    def rsync_migrate_commands(shell, rsync, timeout = 0)
      shell.as_root(rsync, 7200)
      shell.as_root("sed -i 's/\/var\/log//g' #{EXCLUSIONS}")
    rescue Timeout::Error
      timeout += 1
      retry if timeout < 3

      raise
    end

    # Public: Create a temporary ssh key to be used for passwordless access to
    # the destination host.
    #
    # shell - SSH object logged in to the source host.
    #
    # Returns a String containing the host's new ssh public key.
    def generate_keypair(shell)
      keygen_command = "ssh-keygen -b 4096 -q -t rsa -f #{PRIVATE_KEY} -P ''"
      shell.as_root(p "mkdir #{DATA_DIR}")
      shell.as_root(p keygen_command, 3600)
      shell.as_root(p "cat #{PUBLIC_KEY}")
    end

    # Public: Prepare the source host for migration by populating the
    # exclusions list in the file located at EXCLUSIONS and determining the
    # location of rsync on the system.
    #
    # shell      - SSH object logged in to the source host.
    #
    # Returns a String containing path to rsync on the host if present.
    def determine_rsync(shell)
      shell.as_root('which rsync 2>/dev/null')
    end

    # Public: Transfer rsync from the destination host to the source host to
    # facilitate the migration.
    #
    # source_shell - SSH object logged in to the source host.
    # dest_shell   - SSH object logged in to the source host.
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
      prepare_destination_filesystem(shell)
      prepare_destination_rsync(shell)
      prepare_destination_pubkey(shell, pubkey)
    end

    # Public: Mount the destination host's target device and make backups of
    # authentication-related files (passwd, group, shadow).
    #
    # shell  - SSH object logged in to the destination host.
    #
    # TODO: Dynamic mountpoint/block device support
    # Presently mount point and block device are hard-coded.  This will be
    # changed in a future release.
    #
    # Returns nothing.
    def prepare_destination_filesystem(shell)
      preserve_files = ['passwd', 'shadow', 'group']
      path = "#{MOUNT_POINT}/etc"

      UI.spinner('Preparing the destination filesystem') do
        shell.as_root("mkdir -p #{MOUNT_POINT}")
        shell.as_root("mount -o acl /dev/xvdb1 #{MOUNT_POINT}")

        preserve_files.each do |file|
          original = "#{path}/#{file}"
          backup   = "#{original}.migration"
          shell.as_root("[ -f #{backup} ] || /bin/cp -a #{original} #{backup}")
        end
      end
    rescue Timeout::Error
      retry_exit('Host is slow to respond while preparing the destination.')
      retry
    end

    # Public: Verify that rsync is installed on the destination host,
    # installing needed.
    #
    # shell  - SSH object logged in to the destination host.
    #
    # TODO: Better distro support
    # Only Debian- and RedHat-based Unix hosts support automatic rsync
    # installation at this time.  This will be fixed in a future release.
    #
    # Raises NoRsyncAvailable if rsync doesn't exist on the destination host.
    #
    # Returns nothing.
    def prepare_destination_rsync(shell)
      UI.spinner('Verifying rsync is present on the destination host') do
        unless /rsync error/.match(shell.as_root('rsync'))
          package_manager = shell.as_root('which {yum,apt-get} 2>/dev/null')
          raise NoRsyncAvailable if package_manager.empty?
          shell.as_root("#{package_manager} install rsync -y", 300)
        end
      end
    rescue Timeout::Error
      retry_exit('Host is slow to respond while preparing the destination.')
      retry
    end

    # Public: Verify that rsync is installed on the destination host,
    # installing needed.
    #
    # shell  - SSH object logged in to the destination host.
    #
    # TODO: Better distro support
    # Only Debian- and RedHat-based Unix hosts support automatic rsync
    # installation at this time.  This will be fixed in a future release.
    #
    # Raises NoRsyncAvailable if rsync doesn't exist on the destination host.
    #
    # Returns nothing.
    def prepare_destination_pubkey(shell, pubkey)
      UI.spinner('Installing source host public key') do
        ssh_key = "mkdir $HOME/.ssh; chmod 0700 $HOME/.ssh; printf " +
                  "'#{pubkey}\\n' >> $HOME/.ssh/authorized_keys"
        shell.as_root(ssh_key)
      end
    rescue Timeout::Error
      retry_exit('Host is slow to respond while preparing the destination.')
      retry
    end

    # Public: For each watchdog in a collection, stop the watchdog.
    #
    # watchdogs - Hash containing name => Watchdog mappings.
    #
    # Returns nothing.
    def stop_watchdogs(watchdogs)
      watchdogs.each { |watchdog| stop_watchdog(watchdog) }
    end

    # Public: Stop a given watchdog, reporting on the status.
    #
    # watchdog - Watchdog object to be stopped.
    #
    # Returns nothing.
    def stop_watchdog(watchdog)
      UI.spinner("Stopping watchdog: #{watchdog.name}") { watchdog.stop }
    rescue Timeout::Error
    end

    # Public: Start all watchdogs for a migration.
    #
    # source_shell - SSH object logged in to the source host.
    # dest_shell   - SSH object logged in to the destination host.
    #
    # Returns a Hash containing name => Watchdog mappings.  Watchdogs will have
    # no alarms set.
    def create_watchdogs(source_shell, dest_shell)
      source_watchdogs(source_shell) + dest_watchdogs(dest_shell)
    end

    # Public: Start all watchdogs to monitor a source host.
    #
    # source - SSH object logged in to the source host.
    #
    # Returns a Hash containing name => Watchdog mappings.  Watchdogs will have
    # no alarms set.
    def source_watchdogs(shell)
      [:system_load,:utilized_memory].map do |e|
        start_watchdog(:source, e, shell)
      end
    end

    # Public: Start all watchdogs to monitor a destination host.
    #
    # source - SSH object logged in to the destination host.
    #
    # Returns a Hash containing name => Watchdog mappings.  Watchdogs will have
    # no alarms set.
    def dest_watchdogs(shell)
      [:system_load,:utilized_memory, :used_space].map do |e|
        start_watchdog(:destination, e, shell)
      end
    end

    # Public: Start a watchdog on a given host.
    #
    # location - Symbol or String containing the name of the location where the
    #            watshdog should be run.
    # name     - Symbol or String describing the watchdog in question.
    # source   - SSH object logged in to the host which the watchdog should
    #            monitor.
    #
    # Returns a Hash containing name => Watchdog mappings.  Watchdogs will have
    # no alarms set.
    def start_watchdog(location, name, shell)
      display = "#{location} #{name}".capitalize
      UI.spinner("Starting watchdog: #{display}") do
        Watchdogs.send(name, shell, display)
      end
    rescue Timeout::Error
      failed = name.to_s.gsub(/_/, ' ').capitalize
      retry_exit("Timed out starting the #{failed} watchdog.")
      retry
    end

    # Public: Set watchdogs up with default alarms.
    #
    # watchdogs - Array containing all default watchdogs.
    # worker    - Thread containing the migration worker.
    #
    # Returns nothing.
    def set_watchdog_alerts(watchdogs, worker)
      watchdogs.each do |watchdog|
        Watchdogs.send("set_alarm_#{watchdog.name}", watchdog, worker)
      end
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

    # Public: For each IP detected on the source host, perform IP remediation
    # on the destination host post-migration.  Allow the list of IPs and the
    # list of directories to target to be overridden by the user.
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

      puts "Detected IPs on the source: #{source_ips.join(', ')} "
      if UI.prompt_yn('Edit IP list? (Y/N)', default_answer: 'N')
        source_ips = edit_ip_list(source_ips)
      end

      puts 'By default only config files under /etc will be remediated.  '
      if UI.prompt_yn('Edit remediation targets? (Y/N)', default_answer: 'N')
        target_directories = edit_directory_list(target_directories)
      end

      puts "Detected IPs on the destination: #{destination_ips.join(', ')}"
      source_ips.each do |ip|
        appropriate = destination_ips.select do |dest_ip|
          Addrinfo.ip(ip).ipv4_private? == Addrinfo.ip(dest_ip).ipv4_private?
        end
        suggested = appropriate.first || destination_ips.first
        remediate_ip(shell, ip, suggested, target_directories)
      end
    end

    # Public: Perform post-migration IP remediation in configuration files for
    # a given IP.
    #
    # shell              - SSH object logged in to the target host.
    # source_ip          - String containing the IP to replace.
    # default_ip         - String containing an IP to suggest as the default
    #                      replacement.
    # target_directories - Array containing Strings of directories to target
    #                      for IP remediation.
    #
    # Returns nothing.
    def remediate_ip(shell, source_ip, default_ip, target_directories)
      replace = UI.prompt("Replacement for #{source_ip}",
                          allow_empty: true, default_answer: default_ip).strip
      return if replace.empty? || target_directories.empty?

      sed = "sed -i 's/#{source_ip}/#{replace}/g' {} \\;"
      UI.spinner("Remediating IP: #{source_ip}") do
        target_directories.each do |dir|
          shell.as_root("find #{MOUNT_POINT}#{dir} -type f -exec #{sed}", 7200)
        end
      end
    end

    # Public: Wrap retry_prompt, exiting the application if the prompt is
    # declined.
    #
    # message - String containing a failure message.
    # prompt  - Prompt to present to the user (default: 'Try again? (Y/N)').
    #
    # Returns false, or exits.
    def retry_exit(message, prompt = 'Try again? (Y/N)')
      error = UI.red { "#{message}  #{prompt}" }
      exit unless UI.prompt_yn(error, default_answer: 'Y')
    end

    # Public: Display a failure message to the user and prompt whether to
    # retry.
    #
    # message - String containing a failure message.
    # prompt  - Prompt to present to the user (default: 'Try again? (Y/N)').
    #
    # Returns true or false indicating whether the user wishes to retry.
    def retry_prompt(message, prompt = 'Try again? (Y/N)')
      error = UI.red { "#{message}  #{prompt}".strip }
      UI.prompt_yn(error, default_answer: 'Y')
    end
  end
end; end
