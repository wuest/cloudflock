require 'cloudflock'
require 'timeout'
require 'net/ssh'
require 'socket'
require 'thread'

module CloudFlock; module Remote
  # The SSH Class wraps the tasks of logging into a host and interacting with
  # it via SSH.
  #
  # Examples
  #
  #   # Log into root@host.example.com
  #   shell = SSH.new(host: 'host.example.com', pass: 'examplepass')
  #   shell.puts 'ls'
  class SSH
    # Public: String containing arguments to pass to ssh(1)
    SSH_ARGUMENTS = '-o UserKnownHostsFile=/dev/null ' \
                    '-o StrictHostKeyChecking=no '     \
                    '-o NumberOfPasswordPrompts=1 '    \
                    '-o ConnectTimeout=15 '            \
                    '-o ServerAliveInterval=30'

    # Public: Hash containing always-set options for Net::SSH
    NET_SSH_OPTIONS = { user_known_hosts_file: '/dev/null', paranoid: false }

    # Public: Prompt to be set on a host upon successful login.
    PROMPT = '@@CLOUDFLOCK@@'

    # Public: Absolute path to the history file to use.
    HISTFILE = '/root/.cloudflock_history'

    # Internal: Default arguments to be used for SSH session initialization.
    DEFAULT_ARGS = {username: '', password: '', ssh_key: '', port: 22}

    # Internal: Default settings for calls to #batch.
    DEFAULT_BATCH_ARGS = { timeout: 30, recoverable: true }

    attr_reader :options

    # Public: Create a new SSH object and log in to the specified host via ssh.
    #
    # args - Hash containing arguments relating to the SSH session. (default
    #        defined in DEFAULT_ARGS):
    #        :hostname       - String containing the address of the remote
    #                          host.
    #        :username       - String containing the remote user with which to
    #                          log in.  (default: '')
    #        :password       - String containing the password with which to log
    #                          in.  (default: '')
    #        :port           - Fixnum specifying the port to which to connect.
    #                          (default: 22)
    #        :ssh_key        - String containing the path to an ssh private
    #                          key.  (default: '')
    #        :key_passphrase - The passphrase for the ssh key if applicable.
    #                          (default: '')
    #
    # Raises InvalidHostname if host lookup fails.
    # Raises LoginFailed if logging into the host fails.
    def initialize(args = {})
      @options = sanitize_arguments(DEFAULT_ARGS.merge(args))
      start_session
      start_keepalive_thread
    end

    # Public: Return the hostname of the host.
    #
    # Returns a String.
    def hostname
      options[:hostname]
    end

    # Public: Open a channel and execute an arbitrary command, returning any
    # data returned over the channel.
    #
    # command     - Command to be executed.
    # timeout     - Number of seconds to allow the command to run before
    #               terminating the channel and returning any buffer returned
    #               so far.  A value of 0 or nil will result in no timeout.
    #               (default: 30)
    # recoverable - Whether a Timeout should be considered acceptable.
    #               (default: false)
    # send_data   - Array containing data to be sent to across the channel
    #               after the command has been run. (default: [])
    #
    # Returns a String.
    # Raises Timeout::Error if timeout is reached.
    def query(command, timeout = 30, recoverable = false, send_data = [])
      buffer  = ''
      running = 0

      channel = @ssh.open_channel do |channel|
        channel.request_pty

        channel.exec(command) do |ch, success|
          ch.on_data          { |_,    data| buffer << data }
          ch.on_extended_data { |_, _, data| buffer << data }

          ch.send_data(send_data.join + "\n")
        end
      end

      Timeout::timeout(timeout) { channel.wait }

      buffer.strip
    rescue Timeout::Error
      raise unless recoverable
      channel.close
      buffer.strip
    rescue EOFError
      start_session
      retry
    rescue IO::EAGAINWaitReadable
      sleep 10
      start_session
      retry
    end

    # Public: Call query on a list of commands, allowing optional timeout and
    # recoverable settings per command.
    #
    # commands - Array containing Hashes containing at minimum a command key.
    #            Hash should follow the following specification:
    #            command     - Command to execute.
    #            timeout     - Timeout to specify for the call to #query.
    #                          (default: 30)
    #            recoverable - Whether the call should be considered
    #                          recoverable if the timeout is reached.
    #                          (default: true)
    #
    # Returns an Array containing results of each command.
    def batch(commands)
      commands.map! { |c| DEFAULT_BATCH_ARGS.merge(c) }
      commands.map  { |c| query(c[:command], c[:timeout], c[:recoverable]) }
    end

    # Public: Wrap query, guaranteeing that the user performing the given
    # command is root.
    #
    # command     - Command to be executed.
    # timeout     - Number of seconds to allow the command to run before
    #               terminating the channel and returning any buffer returned
    #               so far.  A value of 0 or nil will result in no timeout.
    #               (default: 30)
    # recoverable - Whether a Timeout should be considered acceptable.
    #               (default: false)
    #
    # Returns a String.
    # Raises Timeout::Error if timeout is reached.
    def as_root(command, timeout = 30, recoverable = false)
      return query(command, timeout, recoverable) if root?

      priv    = 'su -'
      priv    = 'sudo ' + priv if options[:sudo]
      uid     = ['id;logout||exit']
      command = ["#{command};logout||exit"]

      passwordless = query(priv, timeout, true, uid)

      unless /uid=0/.match(passwordless)
        command.unshift(options[:root_password] + "\n")
      end

      buffer = query(priv, timeout, recoverable, command)
      cleanup = Regexp.new("^#{Regexp::escape(command.join)}\r\n")
      buffer.gsub(cleanup, '')
    end

    # Public: Terminate the active ssh session.
    #
    # Returns nothing.
    def logout!
      @ssh.close
      @ssh = nil
    end

    private

    # Private: Indicates whether the logged-in user is root.
    #
    # Returns true if the current user is UID 0, false otherwise.
    def root?
      @uid || @uid = fetch_uid
    end

    # Private: Fetch the uid of the logged in user, return true if the uid is
    # zero.
    #
    # Returns true if the current user is UID 0, false otherwise.
    def fetch_uid
      uid = query('id')
      return false unless uid.gsub!(/.*uid=(\d+).*/, '\\1').to_i == 0
      true
    end

    # Internal: Sanitize arguments to be used
    #
    # args - Hash containing arguments relating to the SSH session:
    #        :host           - String containing the address of the remote
    #                          host.
    #        :username       - String containing the remote user with which to
    #                          log in.  (default: '')
    #        :password       - String containing the password with which to log
    #                          in.  (default: '')
    #        :port           - Fixnum specifying the port to which to connect.
    #                          (default: 22)
    #        :ssh_key        - String containing the path to an ssh private
    #                          key.  (default: '')
    #        :key_passphrase - The passphrase for the ssh key if applicable.
    #                          (default: '')
    #
    # Returns a Hash containing sanitized arguments suitable for passing to
    # Net::SSH.  Not that #filter_ssh_arguments should be called to guarantee
    # inappropriate options are not passed to Net::SSH::start.
    def sanitize_arguments(args)
      # Resolve the host to an IP
      args[:host] = lookup_hostname(args[:hostname])
      args[:port] = args[:port].to_i

      # Username should be lowercase, alphanumeric only.
      args[:username].downcase!
      args[:username].gsub!(/[^a-z0-9_-]/, '')

      # Remove control characters from password
      args[:password].tr!("\u0000-\u001f\u007f\u2028-\u2029", '')

      # Read in ssh key data if able.
      if File.file?(args[:ssh_key])
        key_path = File.expand_path(args[:ssh_key].to_s)
        args[:key_data] = File.read(key_path)
      end

      args
    rescue Errno::EACCES
      args
    end

    # Internal: Filter all arguments not suitable to be passed to
    # Net::SSH::start.
    #
    # args - Hash containing arguments to filter.
    #
    # Returns a Hash with only the keys :port, :password, :key_data and
    # :key_passphrase defined.
    def filter_ssh_options(args)
      valid_arguments = [:port, :password, :key_data, :key_passphrase]
      args.select { |opt| valid_arguments.include? opt }.merge(NET_SSH_OPTIONS)
    end

    # Internal: Resolve the hostname provided and return the network address to
    # which it maps.
    #
    # host - String containing the hostname or IP to verify.
    #
    # Returns a String containing an IP.
    #
    # Raises InvalidHostname if address information cannot be obtained for
    # the specified host.
    def lookup_hostname(host)
      Socket.getaddrinfo(host, nil, nil, Socket::SOCK_STREAM)[0][3]
    rescue SocketError
      raise(InvalidHostname, Errstr::INVALID_HOST % host)
    end

    # Internal: Start an SSH session.
    #
    # Sets @ssh.
    #
    # Returns nothing.
    #
    # Raises TooManyRetries if retry_count is greater than 4.
    def start_session
      ssh_opts = filter_ssh_options(options)
      @ssh = Net::SSH.start(options[:hostname], options[:username], ssh_opts)
    rescue Net::SSH::Disconnect
      retry_count = retry_count.to_i + 1
      sleep 30 and retry if retry_count < 5
      raise(SSHCannotConnect, Errstr::CANNOT_CONNECT % options[:hostname])
    end

    # Internal: Creates a thread which sends a keepalive message every 10
    # seconds.
    #
    # Sets @keepalive.
    #
    # Returns nothing.
    def start_keepalive_thread
      @keepalive.kill if @keepalive.is_a?(Thread)
      @keepalive = Thread.new do
        loop do
          sleep 10
          @ssh.send_global_request('keepalive@openssh.com')
        end
      end
    end
  end
end; end
