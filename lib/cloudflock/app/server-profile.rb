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
      source_host = options.dup

      source_host = define_source(options)
      source_ssh  = connect_source(source_host)

      profile = UI.spinner("Checking source host") do
        CloudFlock::Task::ServerProfile.new(source_ssh)
      end

      puts generate_report(profile)
      puts profile.process_list if options[:verbose]
    end

    private

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
