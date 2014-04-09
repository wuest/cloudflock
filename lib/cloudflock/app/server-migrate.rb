require 'cloudflock/app/common/servers'
require 'cloudflock/task/server-profile'
require 'cloudflock/app'
require 'tempfile'
require 'fog'

module CloudFlock; module App
  # Public: The ServerMigrate class provides the interface to perform one-shot
  # migrations as a CLI application.
  class ServerMigrate
    include CloudFlock::App::Common
    include CloudFlock::Remote

    # Public: Perform the steps necessary to migrate a Unix host to a standing
    # host or to a newly provisioned Rackspace Cloud server.
    def initialize
      options = parse_options

      source_host = source_connect(options)
      profile = fetch_profile(source_host)

      puts generate_recommendation(profile)

      dest_host = destination_connect(options, profile)
      exclusions = build_exclusions(profile.cpe)
      migrate_server(source_host, dest_host, exclusions)

      source_host.logout!
      cleanup_destination(dest_host, profile.cpe)
      configure_ips(dest_host, profile)

      puts UI.bold { UI.blue { "Migration complete to #{dest_host.hostname}"} }
    rescue
      puts UI.red { 'An unhandled error was encountered.  Details follow:' }
      raise
    end

    private

    # Internal: Profile a server in order to make accurate recommendations.
    #
    # source_ssh - SSH object connected to a Unix host.
    #
    # Returns a ServerProfile object.
    def fetch_profile(source_ssh)
      UI.spinner("Checking source host") do
        CloudFlock::Task::ServerProfile.new(source_ssh)
      end
    end

    # Internal: Collect information needed to connect to the source host for a
    # migration.  Connect to the target host.
    #
    # options - Hash containing information to connect to an existing host.
    #
    # Returns an SSH object connected to the source host.
    def source_connect(options)
      source_host = define_source(options)
      ssh_connect(source_host)
    end

    # Internal: Collect information needed to either connect to an existing
    # host or provision a new one on Rackspace Cloud to be used as a target
    # for migration.  Connect to the target host.
    #
    # options - Hash containing information to connect to an existing host.
    # profile - ServerProfile for the source host.
    #
    # Returns an SSH object connected to the target host.
    def destination_connect(options, profile)
      if options[:resume]
        dest_host = define_destination(options)
      else
        api = define_rackspace_api
        managed = UI.prompt_yn('Managed account? (Y/N)', default_answer: 'N')
        dest_host = create_cloud_instance(api, profile, managed)
      end

      ssh_connect(dest_host)
    end

    # Internal: Provision a new instance on the Rackspace cloud and return
    # credentials once finished.
    #
    # api     - Hash containing credentials to interact with the Rackspace
    #           Cloud API.
    # profile - ServerProfile for the source host.
    # managed - Whether the account is a Managed Cloud account (needed to know.
    #           whether to wait for post-provisioning automation to finish)
    #
    # Returns a Hash containing credentials suitable for logging in via SSH.
    def create_cloud_instance(api, profile, managed)
      api = define_rackspace_cloudservers_region(api)
      compute = Fog::Compute.new(api)
      image = define_compute_image(compute, profile)
      flavor = define_compute_flavor(compute, profile)
      name = define_compute_name(profile)

      compute_spec = { image_id: image, flavor_id: flavor, name: name }
      provision_compute(compute, managed, compute_spec)
    end

    # Internal: Generate a recommendation based on the results of profiling a
    # host.
    #
    # profile - ServerProfile for the source host.
    #
    # Returns a String.
    def generate_recommendation(profile)
      os  = profile_os_string(profile)
      ram = profile_ram_string(profile)
      hdd = profile_hdd_string(profile)

      "OS:  " + UI.bold { os } + "\n" +
      "RAM: " + UI.bold { ram } + "\n" +
      "HDD: " + UI.bold { hdd } + "\n" +
      UI.red  { UI.bold { profile.warnings.join("\n") } }
    end

    # Internal: Build exclusions list based on a host's CPE.
    #
    # cpe - CPE object describing a given host.
    #
    # Returns a String
    def build_exclusions(cpe)
      exclusions = Exclusions.new(cpe)
      edit = UI.prompt_yn('Edit exclusions list? (Y/N)', default_answer: 'N')
      exclusions = edit_exclusions(exclusions) if edit

      exclusions.to_s
    end

    # Internal: Allow editing of the default exclusions for a given platform.
    #
    # exclusions - String containing exclusions.
    #
    # Returns a String.
    def edit_exclusions(exclusions)
      temp_file('exclusions', exclusions)
    end

    # Internal: Allow editing of a list of IPs.
    #
    # ips - Array containing Strings of IPs.
    #
    # Returns an Array containing Strings of IPs.
    def edit_ip_list(ips)
      temp_file('ips', ips.join("\n")).split(/\s+/)
    end

    # Internal: Allow editing of a list of target directories.
    #
    # dirs - Array containing Strings of paths.
    #
    # Returns an Array containing Strings of paths.
    def edit_directory_list(dirs)
      temp_file('directories', dirs.join("\n")).split(/\s+/)
    end

    # Internal: Generate a String describing a host's operating system.
    #
    # profile - ServerProfile for the source host.
    #
    # Returns a String.
    def profile_os_string(profile)
      os = profile.select_entries(/System/, 'OS')
      os += profile.select_entries(/System/, 'Arch')
      os.map(&:capitalize).join(' ')
    end

    # Internal: Generate a String describing a host's memory usage.
    #
    # profile - ServerProfile for the source host.
    #
    # Returns a String.
    def profile_ram_string(profile)
      profile.select_entries(/Memory/, /Used RAM/).join.strip
    end

    # Internal: Generate a String describing a host's disk usage.
    #
    # profile - ServerProfile for the source host.
    #
    # Returns a String.
    def profile_hdd_string(profile)
      profile.select_entries(/Storage/, /Usage/).join(' ').strip
    end

    # Internal: Set up a temporary file, open it for editing locally, and read
    # it back in after finished.
    #
    # name    - Name to append to the temporary file's path.
    # content - Content with which the temporary file should be pre-populated.
    #
    # BUG: Works only on POSIX-compliant hosts; needs work to support Windows.
    #
    # Returns a String.
    def temp_file(name, content)
      editor = File.exists?('/usr/bin/editor') ? '/usr/bin/editor' : 'vi'

      temp = Tempfile.new("cloudflock_#{name}")
      temp.write(content)
      temp.close

      system("#{editor} #{temp.path}")
      temp.open
      result = temp.read
      temp.close
      temp.unlink

      result
    end

    # Internal: Set up an OptionParser object to recognize options specific to
    # profiling a remote host.
    #
    # Returns nothing.
    def parse_options
      options = {}

      CloudFlock::App.parse_options(options) do |opts|
        opts.separator 'Perform host-level migration'
        opts.separator ''
        opts.separator 'Options for source definition:'

        begin # Source options
          opts.on('-h', '--src-host HOST', 'Address for source host') do |host|
            options[:hostname] = host
          end

          opts.on('-p', '--src-port PORT',
                  'Source SSH port for source host') do |port|
            options[:port] = port
          end

          opts.on('-u', '--src-user USER',
                  'Username for source host') do |user|
            options[:username] = user
          end

          opts.on('-a', '--src-password [PASSWORD]',
                  'Password for source host login') do |pass|
            options[:password] = pass
          end

          opts.on('-s', '--src-sudo', 'Use sudo to gain root on source host') do
            options[:sudo] = true
          end

          opts.on('-n', '--src-no-sudo', 'Use su to gain root on source host') do
            options[:sudo] = false
          end

          opts.on('-r', '--src-root-pass PASS',
                  'Password for root user on the source host') do |root|
            options[:root_password] = root
          end

          opts.on('-i', '--src-identity IDENTITY',
                  'SSH identity to use for the source host') do |key|
            options[:ssh_key] = key
          end
        end

        opts.separator ''
        opts.separator 'Options for destination (if not using automation):'

        begin # Destination options
          opts.on('-H', '--dest-host HOST',
                  'Address for destination host') do |host|
            options[:dest_hostname] = host
          end

          opts.on('-P', '--dest-port PORT',
                  'Source SSH port for destination host') do |port|
            options[:dest_port] = port
          end

          opts.on('-U', '--dest-user USER',
                  'Username for destination host') do |user|
            options[:dest_username] = user
          end

          opts.on('-A', '--dest-password [PASSWORD]',
                  'Password for destination host login') do |pass|
            options[:dest_password] = pass
          end

          opts.on('-S', '--dest-sudo', 'Use sudo to gain root on destination host') do
            options[:dest_sudo] = true
          end

          opts.on('-N', '--dest-no-sudo', 'Use su to gain root on destination host') do
            options[:dest_sudo] = false
          end

          opts.on('-R', '--dest-root-pass PASS',
                  'Password for root user on the destination host') do |root|
            options[:dest_root_password] = root
          end

          opts.on('-I', '--dest-identity IDENTITY',
                  'SSH identity to use for the destination host') do |key|
            options[:dest_ssh_key] = key
          end
        end

        opts.separator ''
        opts.separator 'Operation options:'

        begin # Operation options
          opts.on('--resume', '--pre-provisioned',
                  'Migrate over standing host ("resume" mode)') do
            options[:resume] = true
          end
          opts.on('--echo-passwords',
                  'Echo entered passwords to the console') do
            options[:password_echo] = true
          end
        end
      end
    end
  end
end; end
