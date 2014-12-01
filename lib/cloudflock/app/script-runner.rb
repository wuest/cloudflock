require 'cloudflock/app/common/servers'
require 'cloudflock/task/script-runner'
require 'cloudflock/app'

module CloudFlock; module App
  # Public: The ServerProfile class provides the interface to produce profiles
  # describing hosts running Unix-like operating systems as a CLI application.
  class ScriptRunner
    include CloudFlock::App::Common
    include CloudFlock::Remote

    # Public: Connect to and profile a remote host, then display the gathered
    # information.
    def initialize
      options   = parse_options
      servers   = options[:servers]
      servers ||= [options]
      script = options[:script] || locate_script

      targets = servers.map { |server| define_source(server.dup) }

      results = targets.map do |host|
        [ host[:hostname], run_script(host, script) ]
      end
      output = results.map { |host, out| "#{UI.green { host}}:\n#{out}" }

      puts
      puts 'Script output'
      puts output.join("\n\n")
    end

    private

    # Internal: Run a script on a given host.
    #
    # host   - Hash containing information necessary to log in to a given host.
    # script - ScriptRunner object.
    #
    # Returns a String containing the result of running the script, if any.
    def run_script(host, script)
      ssh  = connect_source(host)

      UI.spinner("Performing task on #{host[:hostname]}") do
        script.run(ssh)
      end
    end

    # Internal: Prompt the use for the location of a script to run, then set up
    # a ScriptRunner.
    #
    # Returns a ScriptRunner.
    def locate_script
      location = UI.prompt_filesystem('Location of script to run')
      CloudFlock::Task::ScriptRunner.new(location)
    end

    # Internal: Set up an OptionParser object to recognize options specific to
    # running a script across several hosts.
    #
    # Returns nothing.
    def parse_options
      options = {}

      CloudFlock::App.parse_options(options) do |opts|
        opts.separator 'Generate a report for a host'
        opts.separator ''

        opts.on('-s', '--script SCRIPT', 'Script to run') do |name|
          options[:script] = CloudFlock::Task::ScriptRunner.new(name)
        end
      end
    end
  end
end; end
