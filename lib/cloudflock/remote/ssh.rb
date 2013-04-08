require 'cloudflock'
require 'expectr'
require 'socket'

# Public: Wrap the tasks of logging into remote hosts via ssh and interacting
# with them through Expectr.
#
# Examples
#
#   # Log in to remote host 'host.example.com'
#   shell = SSH.new(host: 'host.example.com', pass: 'examplepass')
class CloudFlock::Remote::SSH
  # Public: Arguments to pass to ssh for when logging into remote hosts
  SSH_ARGUMENTS = %w{-o UserKnownHostsFile=/dev/null -o
  StrictHostKeyChecking=no -o NumberOfPasswordPrompts=1 -o
  ConnectTimeout=15 -o ServerAliveInterval=30}.join(' ')

  # Public: String used to standardize and identify the shell's prompt
  PROMPT = '@@MIGRATE@@'

  # Public: String representing the location of the history file
  HISTFILE = '/root/.migration_history'

  # Public: Initialize a new SSH object and automatically log in via SSH to
  # the host with provided address/credentials.
  #
  # args - A Hash used to specify optional arguments (default: {}):
  #        :host         - String used to specify the address to which to
  #                        connect.
  #        :username     - String containing the remote user to use.
  #                        (default: "root")
  #        :password     - String containing the password to use for the user
  #                        specified with :user. (default: "")
  #        :port         - Fixnum specifying the port to which to connect.
  #                        (default: 22)
  #        :flush_buffer - Boolean specifying whether or not to flush output
  #                        to STDOUT. (default: false)
  #        :timeout      - Fixnum specifying the timeout for the Expectr object
  #                        to use. (default: 30)
  #
  # Raises InvalidHostname if no host is specified.
  # Raises InvalidHostname if looking up the host fails.
  # Raises LoginFailed if logging in fails.
  def initialize(args = {})
    unless args[:host].kind_of?(String) && args[:host].length > 0
      raise InvalidHostname, "No host specified"
    end

    begin
      args[:host] = lookup_hostname(args[:host])
    rescue SocketError
      raise InvalidHostname, "Unable to look up host: #{args[:host]}"
    end

    # Set up the rest of the arguments Hash
    args[:username] ||= ''
    args[:password] ||= ''
    args[:flush_buffer] = false if args[:flush_buffer].nil?
    args[:username] ||= 'root'
    args[:timeout] ||= 30
    args[:port] ||= 22
    args[:public_key] ||= ''

    # Sanitize the arguments Hash
    args[:username].downcase!
    args[:username].gsub!(/[^a-z0-9_-]/, '')
    args[:port] = args[:port].to_i
    args[:password].tr!("\u0000-\u001f\u007f\u2028-\u2029", '')

    # Build the SSH command to send to the system
    command = "ssh #{SSH_ARGUMENTS}"
    if File.file?(File.expand_path(args[:public_key]))
      command << " -i #{File.expand_path(args[:public_key])}"
    end
    if args[:username].length > 0
      args[:username] << '@'
    end
    command << " #{args[:username]}#{args[:host]} -p #{args[:port]}"
    @expect = Expectr.new(command, flush_buffer: args[:flush_buffer],
                          timeout: args[:timeout])

    raise LoginFailed unless login(args[:password])
  rescue Timeout::Error, Expectr::ProcessError
    raise LoginFailed
  end

  # Public: Verify the host passed and return network address to which it's
  # mapped.
  #
  # host - String containing the hostname or IP to verify
  #
  # Returns a String containing an IP
  def lookup_hostname(host)
    Socket.getaddrinfo(host, nil, nil, Socket::SOCK_STREAM)[0][3]
  end

  # Public: Wrap authentication and provide passwords if requested.  Upon
  # detecting successful authentication, set the shell's PS1 to PROMPT.
  #
  # password - String containing the password to provide if requested.
  #            (default: "")
  #
  # Returns true or false indicating login success.
  def login(password = '')
    @expect.expect(/password/i, true) do |match|
      @expect.puts(password) if match.to_s =~ /password/i
    end

    # Wait to get a response (e.g. prompt), then set PS1
    count = 0
    continue = false
    until continue
      if count == 5
        @expect.kill!
        return false
      end

      sleep 5
      @expect.clear_buffer!
      @expect.puts
      continue = @expect.expect(/./, true).to_s =~ /./
      count += 1
    end
    return false if @expect.pid == 0
    @expect.puts("export PS1='#{PROMPT} '")
    true
  end

  # Public: Check to see if the shell attached to the SSH object has superuser
  # priveleges.
  #
  # Returns false if root privileges are detected, true otherwise.
  def check_root
    @expect.clear_buffer!
    uid = query("UID_CHECK", command = "id")
    root = /uid=0\(.*$/.match(uid)
    root.nil?
  end

  # Public: Determine if currently logged in user is the superuser and, if
  # not, attempt to gain superuser permissions via su/sudo.
  #
  # password - String containing password to use.
  # use_sudo - Boolean value denoting whether to use sudo to obtain root
  #            privileges. (default: false)
  #
  # Returns nothing.
  # Raises StandardError if we are unable to obtain root.
  def get_root(password, use_sudo = false)
    match = nil
    if check_root
      @expect.send("sudo ") if use_sudo
      @expect.puts("su -")
      login(password)
    end

    raise RootFailed, "Unable to obtain root permissions" if check_root

    @expect.puts("export PS1='#{PROMPT} '")
    @expect.puts("export HISTFILE='#{HISTFILE}'")

    set_timeout(5) do
      while prompt(true)
      end
    end
  end

  # Public: Log out of any active shells.  Attempt a maximum of 10 logouts,
  # then kill the ssh process if the Expectr object still reports a live pid.
  #
  # Returns nothing.
  def logout!
    count = 0
    while @expect.pid > 0 && count < 10
      count += 1
      @expect.clear_buffer!
      @expect.puts
      prompt(true)
      @expect.puts("exit")

      sleep 1
    end

    @expect.kill!
  rescue ArgumentError, Expectr::ProcessError
    # Raised if puts or kill! fails.
  end

  # Public: Wait for a prompt from the SSH object.
  #
  # recoverable - Boolean specifying whether the prompt is recoverable if no
  #               match is found. (default: false)
  #
  # Returns nothing.
  def prompt(recoverable=false)
    unless recoverable.kind_of?(TrueClass) || recoverable.kind_of?(FalseClass)
      raise ArgumentError, "Should specify true or false"
    end

    @expect.expect(PROMPT, recoverable)
  end

  # Public: Set the Expectr object's timeout.
  #
  # timeout - Fixnum containing the number of seconds which the Expectr object
  #           should use as its timeout value, either temporarily or until set
  #           explicitly again.
  #
  # Returns nothing.
  # Yields nothing.
  # Raises ArgumentError if timeout is not a Fixnum.
  def set_timeout(timeout)
    unless timeout.kind_of?(Fixnum) && timeout > 0
      raise ArgumentError, "Expected an integer greater than 0"
    end

    if block_given?
      old_timeout = @expect.timeout
      @expect.timeout = timeout
      result = yield
      @expect.timeout = old_timeout
      return result
    else
      @expect.timeout = timeout
    end
  end

  # Public: Print a tag to a new line, followed by the output of an arbitrary
  # command, then the tag again.  Return everything between the two tags.
  #
  # tag         - String containing the tag to use to isolate command output.
  #               This string must not be empty after being constrained to
  #               /[a-zA-Z0-9_-]/.  (default: "SSH_TAG")
  # command     - Command to send to the active ssh session.
  # recoverable - Whether a timeout should be considered recoverable or fatal.
  #               (default: false)
  #
  # Returns a MatchData object from the Expectr object.
  # Raises ArgumentError if tag or command aren't Strings.
  # Raises ArgumentError if the tag String is empty.
  def query(tag = "SSH_TAG", command = "", recoverable = false)
    raise ArgumentError unless command.kind_of?(String) && tag.kind_of?(String)

    tag.gsub!(/[^a-zA-Z0-9_-]/, '')
    raise ArgumentError, "Alphanumeric tag required" if tag.empty?

    @expect.send('printf "' + tag + '\n";')
    @expect.send(command.gsub(/[\r\n]/, ' '))
    @expect.puts(';printf "\n' + tag + '\n";')

    match = @expect.expect(/^#{tag}.*^#{tag}/m, recoverable)
    prompt(recoverable)

    match.to_s.gsub(/^#{tag}(.*)^#{tag}$/m, '\1').strip
  end

  # Public: Set whether or not the Expectr object will flush the internal
  # buffer to STDOUT.
  #
  # flush - Boolean denoting whether to flush the buffer.
  #
  # Returns nothing.
  def flush_buffer(flush)
    @expect.flush_buffer = flush
  end

  # Public: Provide access to the Expectr object's output buffer.
  #
  # Returns a String containing the buffer.
  def buffer
    @expect.buffer
  end

  # Public: Wrap Expectr#send.
  #
  # command - String containing the data to send to the Expectr object.
  #
  # Returns nothing.
  def send(command)
    @expect.send(command)
  end

  # Public: Wrap Expectr#puts.
  #
  # command - String containing the data to send to the Expectr object.
  #           (default: "")
  #
  # Returns nothing.
  def puts(command = "")
    @expect.puts(command)
  end

  # Public: Wrap Expectr#expect.
  #
  # args - Variable length list of arguments to send to Expectr#expect.
  #
  # Returns a MatchData object once a match is found if no block is given.
  # Yields the MatchData object representing the match.
  # Raises TypeError if something other than a String or Regexp is passed.
  # Raises Timeout::Error if a match isn't found, unless recoverable.
  def expect(*args)
    @expect.expect(*args)
  end

  # Public: Wrap Expectr#clear_buffer!
  #
  # Returns nothing.
  def clear
    @expect.clear_buffer!
  end
end
