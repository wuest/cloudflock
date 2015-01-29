require 'cloudflock/remote/ssh'
require 'cloudflock/log'
require 'cpe'

module CloudFlock; module Task
  class ScriptRunner
    include CloudFlock::Log
    # Public: Initialize the Profile object.
    #
    # shell  - String containing YAML representing the script to be run on each
    #          host.
    # logger - Object which represents a logging facility, if any.
    #          (default: nil)
    def initialize(script, logger = nil)
      @logger = logger
      @script = File.read(File.expand_path(script))
    end

    # Public: Run the script on a given host.
    #
    # shell - An SSH object which is open to the host which will be profiled.
    #
    # Returns a String containing the output of the shell script if any.
    def run(shell)
      filename = "cloudflock_script_#{Time.now.to_f}.sh"

      as_root(shell, "cat <<EOF> #{filename}\n#{script}\nEOF")
      as_root(shell, "/bin/sh #{filename}", 0)
    end

    private
    attr_reader :script, :logger

    # Internal: Perform a command as the root user on a shell session,
    # attempting to log the information.
    #
    # shell   - An SSH object which is open to the host on which the command
    # should be run.
    # command - String containing the command to be run.
    # timeout - Number of seconds to allow before the command is considered to
    #           be failed.  0 Seconds will allow the command to run forever.
    #           (default: 30)
    #
    # Returns a String containing any output of the command run.
    def as_root(shell, command, timeout = 30)
      log(command, '> ')
      output = shell.as_root(command, timeout)
      log(output, '< ')
    end
  end
end; end
