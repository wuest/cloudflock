require 'cloudflock/app/common/servers'
require 'cloudflock/task/server-profile'
require 'cloudflock/app'

module CloudFlock; module App
  # Public: The ServerProfile class provides the interface to produce profiles
  # describing hosts running Unix-like operating systems as a CLI application.
  class ServerProfile
    include CloudFlock::App::Common
    include CloudFlock::Remote

    # Public: Connect to and profile a remote host, then display the gathered
    # information.
    def initialize
      options     = parse_options
      servers     = options[:servers]
      logger      = options[:logger]
      save_option = true unless servers
      servers   ||= [options]

      results = servers.map do |server|
        profile_host(server.dup, save_option, logger)
      end

      printable = results.map do |hash|
        name = hash.keys.first
        profile = hash[name]
        UI.bold { UI.green { "#{name}\n" } } +
        generate_report(profile) +
        (options[:verbose] ? profile.process_list.to_s : "")
      end

      puts printable.join("\n\n")
    end

    private

    def profile_host(source_host, save_option, logger)
      source_host = define_source(source_host)
      save_config(source_host) if save_option && save_config?

      source_ssh  = connect_source(source_host)

      profile = UI.spinner("Checking source host") do
        CloudFlock::Task::ServerProfile.new(source_ssh, logger)
      end

      {source_host[:hostname] => profile}
    end

    # Internal: Generate a "title" String (bold, 15 characters wide).
    #
    # tag - String to be turned into a title.
    #
    # Returns a String.
    def title(tag)
      UI.bold { "%15s" % tag }
    end

    # Internal: Generate a report containing informational aspects of a host's
    # profile as well as any warnings profiling the host in question generated.
    #
    # profile - Profile object.
    #
    # Returns a String.
    def generate_report(profile)
      profile_hash = profile.to_hash
      host_info(profile_hash[:info]) + host_warnings(profile_hash[:warnings])
    end

    # Internal: Generate a string containing informational aspects of a host's
    # profile.
    #
    # profile - Profile object.
    #
    # Returns a String.
    def host_info(profile)
      profile.map do |section|
        "#{UI.blue { UI.bold { section.title } } }\n" +
        section.entries.reject do |entry|
          entry.values.to_s.empty?
        end.
        map { |entry| title(entry.name) + " #{entry.values}" }.join("\n")
      end.join("\n\n")
    end

    # Internal: Generate a string containing each warning produced by profiling
    # a host.
    #
    # warnings - Array containing Strings.
    #
    # Returns a String.
    def host_warnings(warnings)
        warnings = warnings.map do |entry|
           "* #{entry}"
        end.join("\n")

      unless warnings.empty?
        warnings = UI.red { UI.bold { "\n\nWarnings:\n#{warnings}" } }
      end
      warnings
    end

    def save_config?
      UI.prompt_yn('Save to a config file? (Y/N)', default_answer: 'Y')
    end

    # Internal: Save a configuration file based on the user's earlier answers.
    #
    # source_host - Hash containing parameters to use to log in to a server.
    #
    # Returns nothing.
    def save_config(source_host)
      config_location = determine_config_location(source_host[:hostname])
      if File.exists?(config_location)
        clobber = UI.prompt_yn('Overwrite? (Y/N)', default_answer: 'Y')
        old_config = YAML.load_file(config_location) unless clobber
      end
      old_config ||= {}

      File.open(config_location, 'w') do |file|
        new_servers = old_config[:servers].to_a + [source_host]
        file.write(YAML.dump(old_config.merge({servers: new_servers})))
      end
    end

    # Internal: Prompt the user for a location to save a configuration file.
    #
    # hostname - String containing the hostname of the host.
    #
    # Returns a String containing a filesystem path.
    def determine_config_location(hostname)
      location = File.join(Dir.home, 'cloudflock_' + hostname + '.yaml')
      UI.prompt_filesystem('Configuration file Location',
                           default_answer: location)
    end

    # Internal: Set up an OptionParser object to recognize options specific to
    # profiling a remote host.
    #
    # Returns nothing.
    def parse_options
      options = {}

      CloudFlock::App.parse_options(options) do |opts|
        opts.separator 'Generate a report for a host'
        opts.separator ''

        opts.on('-h', '--host HOST', 'Target host to profile') do |host|
          options[:hostname] = host
        end

        opts.on('-p', '--port PORT', 'Port SSH is listening on') do |port|
          options[:port] = port
        end

        opts.on('-u', '--user USER', 'Username to log in') do |user|
          options[:username] = user
        end

        opts.on('-a', '--password [PASSWORD]', 'Password to log in') do |pass|
          options[:password] = pass
        end

        opts.on('-s', '--sudo', 'Use sudo to gain root') do
          options[:sudo] = true
        end

        opts.on('-n', '--no-sudo', 'Use su to gain root') do
          options[:sudo] = false
        end

        opts.on('-r', '--root-pass PASS', 'Password for root user') do |root|
          options[:root_password] = root
        end

        opts.on('-i', '--identity IDENTITY', 'SSH identity to use') do |key|
          options[:ssh_key] = key
        end
      end
    end
  end
end; end
