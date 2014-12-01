require 'cloudflock/remote/ssh'
require 'cpe'

module CloudFlock; module Task
  class ScriptRunner
    # Public: Initialize the Profile object.
    #
    # shell - String containing YAML representing the script to be run on each
    #         host.
    def initialize(script)
      @script = File.read(File.expand_path(script))
    end

    # Public: Run the script on a given host.
    #
    # shell - An SSH object which is open to the host which will be profiled.
    #
    # Returns a String containing the output of the shell script if any.
    def run(shell)
      filename = "cloudflock_script_#{Time.now.to_f}.sh"
      shell.as_root("cat <<EOF> #{filename}\n#{script}\nEOF")
      shell.as_root("/bin/sh #{filename}", 0)
    end

    private

    attr_reader :script
  end
end; end
