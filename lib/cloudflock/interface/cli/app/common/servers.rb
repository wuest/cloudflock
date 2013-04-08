require 'cloudflock'
require 'cloudflock/interface/cli'
require 'cloudflock/remote/ssh'

# Public: The ServersCommon module provides common methods for CLI interaction
# pertaining to interaction with remote (Unix) servers.
module CloudFlock::Interface::CLI::App::Common::Servers
  include CloudFlock::Target::Servers

  SSH = CloudFlock::Remote::SSH
  CLI = CloudFlock::Interface::CLI::Console

  # Internal: Collect information about the source server to be migrated.
  #
  # opts - Hash containing any applicable options mappings for the server in
  #        question.
  #
  # Returns a Hash containing information pertinent to logging in to a host.
  def define_source(opts)
    host = {}

    host[:host] = opts[:source_host] || CLI.prompt("Source host")
    host[:port] = opts[:source_port] || CLI.prompt("Source SSH port",
                                                   default_answer: "22")
    host[:username] = opts[:source_user] || CLI.prompt("Source username",
                                                       default_answer: "root")
    host[:password] = opts[:source_pass] || CLI.prompt("Source password",
                                                       default_answer: "")

    until host[:public_key].kind_of?(String)
      key = opts[:public_key] || CLI.prompt("SSH Key", default_answer: "")
      if File.file?(File.expand_path(key)) || key.empty?
        host[:public_key] = key
      end
    end

    # Only need to use sudo if the user isn't root
    if host[:username] == "root"
      host[:sudo] = false
    elsif !opts[:source_sudo].nil?
      host[:sudo] = opts[:source_sudo]
    else
      host[:sudo] = CLI.prompt_yn("Use sudo? (Y/N)", default_answer: "Y")
    end

    # We need the root pass if non-root and no sudo
    if host[:username] == "root" || host[:sudo]
      host[:root_pass] = host[:password]
    else
      host[:root_pass] = CLI.prompt("Password for root")
    end

    host
  end

  # Internal: Collect information about the destination server to target in a
  # migration -- only used for resume functions.
  #
  # Returns a Hash containing information pertinent to logging in to a host.
  def define_destination
    host = Hash.new

    host[:host] = CLI.prompt("Destination host")
    host[:password] = CLI.prompt("Destination root password")
    host[:pre_steps] = CLI.prompt_yn("Perform pre-migration steps? (Y/N)")
    host[:username] = "root"

    host
  end

  # Internal: Initiate a connection to a given host and obtain root privileges.
  #
  # host - Hash containing information for connecting to the host:
  #        :host      - String containing the location to which to connect.
  #        :port      - String or Fixnum containing the port on which ssh
  #                     listens. (default: "22")
  #        :username  - String containing the username to use when logging in.
  #        :password  - String containing the password for the above user.
  #        :sudo      - Boolean value defining whether to use sudo to obtain
  #                     root. (default: false)
  #        :root_pass - String containing the password to use to obtain root,
  #                     if the user isn't root and sudo isn't used.
  #        :verbose   - Boolean value defining whether to flush output to
  #                     STDOUT. (default: false)
  #
  # Returns an SSH object.
  # Raises ArgumentError unless at least host and user are defined.
  def host_login(host)
    if host[:host].nil? || host[:username].nil?
      raise ArgumentError, "Need at least host and username defined"
    end

    host[:flush_buffer] = host[:verbose] || false

    ssh = SSH.new(host)
    ssh.get_root(host[:root_pass], host[:sudo])

    ssh
  end

  # Internal: Initiate a connection to a destination host.
  #
  # host - Hash containing information for connecting to the host:
  #        :host      - String containing the location to which to connect.
  #        :password  - String containing the password for the above user.
  #        :verbose   - Boolean value defining whether to flush output to
  #                     STDOUT. (default: false)
  #
  # Returns an SSH object.
  # Raises ArgumentError unless at least host and user are defined.
  def destination_login(host)
    host[:username] = "root"
    message = "Connecting to destination host (password: #{host[:password]})"
    r = 0

    destination_host = CLI.spinner(message) do
      begin
        host_login(host)
      rescue Timeout::Error
        if (r += 1) < 5
          sleep 300
          retry
        end
        raise
      end
    end
  end
end
