require 'cloudflock/remote/ssh'
require 'socket'
require 'cpe'

module CloudFlock; module Target; module Servers
  class Profile
    # Public: List of linux distributions supported by CloudFlock
    SUPPORTED_DISTROS = %w{Arch CentOS Debian SUSE Ubuntu RedHat Gentoo}

    # Public: Initialize the Profile object.
    #
    # shell - An SSH object which is open to the host which will be profiled.
    #
    # Raises TypeError if shell is not of type SSH.
    def initialize(shell)
      unless shell.is_a?(CloudFlock::Remote::SSH)
        raise(TypeError, Errstr::NOT_SSH)
      end

      @shell = shell
      @warnings = []
      @info = {}
    end

    # Public: Build the profile by calling all methods which begin with
    # 'determine_'.
    #
    # Returns nothing.
    def build
      methods.select { |x| x =~ /^determine_/ }.each do |method|
        self.send(method)
      end
      methods.select { |x| x =~ /^warning_/ }.each do |method|
        self.send(method)
      end
    end

    # Public: Allow access to the list of keys in @info.
    #
    # Returns an Array of keys in @info.
    def keys
      @info.keys
    end

    # Public: Simplify access to @info.
    #
    # key - Object to be used as the key in the @info Hash.
    #
    # Returns a value stored in @info.
    def [](key)
      @info[key]
    end

    # Public: Return server information and warnings as a Hash.
    #
    # Returns a Hash.
    def to_hash
      @info.merge({warnings: @warnings})
    end

    private

    # Internal: Determine important statistics relating to the CPU (available
    # core count, speed).
    #
    # Returns nothing.
    def determine_cpu
      cpu = @info[:cpu] = {}

      lscpu = @shell.query('LSCPU', 'lscpu')
      if lscpu.empty?
        cpuinfo = @shell.query('cat /proc/cpuinfo')
        count = cpuinfo.lines.select { |l| l =~ /^processor\s*: [0-9]/}
        speed = cpuinfo.lines.select { |l| l =~ /MHz/ }
        cpu[:count] = count.size
        cpu[:speed] = speed[0].to_s.gsub(/.* /, '')
      else
        cpu[:count] = lscpu.select { |l| l =~ /CPU\(s\)/ }.gsub(/.* /, '')
        cpu[:speed] = lscpu.select { |l| l =~ /MHz/ }.gsub(/.* /, '')
      end
    end

    # Internal: Determine the number and size of MySQL databases resident on
    # the target host.
    #
    # Returns nothing.
    def determine_databases
      db = @info[:db] = {}
      mysql_count_cmd = 'find /var/lib/mysql* -maxdepth 0 -type d ' \
                        '2>/dev/null|wc -l'
      db[:count] = @shell.query('DB_MYSQL_COUNT', mysql_count_cmd)
      db[:count] = db[:count].to_i

      mysql_size_cmd = "du -s /var/lib/mysql 2>/dev/null|awk '{print $1}'"
      db[:size] = @shell.query('DB_MYSQL_SIZE', mysql_size_cmd)
      db[:size] = db[:size].to_i
    end

    # Internal: Determine the amount of disk space in use on the target host.
    #
    # Returns nothing.
    def determine_disk
      df_cmd = "df 2>/dev/null|awk '$1 ~ /\\// {I=I+$3} END {print I}'"
      disk = @shell.query('DISK_DF', df_cmd)

      # Result is expected to be in KiB.  Convert to GB.
      @info[:disk] = disk.to_f / 1000 ** 2
    end

    # Internal: Attempt to determine which linux distribution the target host
    # is running.
    #
    # Returns nothing.
    def determine_distribution
      # Some distros ship with a file containing the CPE for their platform;
      # this should be used if at all possible.
      release = @shell.query('CPE', 'cat /etc/system-release-cpe')
      begin
        cpe = CPE.parse(release)
        cpe.version.gsub!(/[^0-9.]/, '')
        @info[:cpe] = cpe
        return
      rescue ArgumentError
        cpe = CPE.new(part: CPE::OS, product: 'linux')
      end

      # Fall back to depending on /etc/issue if available
      issue = @shell.query('ISSUE', 'cat /etc/issue')
      cpe.vendor = distro_name(issue)

      # If all else fails, resort to looking in release files
      if cpe.vendor.empty?
        release_cmd = "grep -h '^ID=' /etc/[A-Za-z]*[_-][rv]e[lr]*|head -1"
        release = @shell.query("RELEASE", release_cmd)
        cpe.vendor = distro_name(release)
      end

      # Fall back to "Unknown"
      cpe.vendor = "" if cpe.vendor.empty?

      # Version number will be determined from /etc/issue
      cpe.version = version_number(issue)
      @info[:cpe] = cpe
    end

    # Internal: Determine the hostname of the target host.
    #
    # Returns nothing.
    def determine_hostname
      @info[:hostname] = @shell.query('HOST', 'hostname')
    end

    # Internal: Determine the amount of historical IO activity on the target
    # host using sysstat if available.
    #
    # Returns nothing.
    def determine_io
      io = @info[:io] = {}

      iostat = @shell.query('IOSTAT', "iostat -c|sed -n 4p|awk '#{print $4}'")
      io[:wait] = iostat.to_f

      up = @shell.query('UPTIME', "uptime|sed -e 's/.*up\\([^,]*\\),.*/\\1/'")
      io[:uptime] = up.chomp
    end

    # Internal: Determine IPv4 addresses in use by the target host, splitting
    # them into public and private groups.
    #
    # Returns nothing.
    def determine_ips
      ips = @info[:ip] = {private: [], public: []}

      ifc_cmd = "/sbin/ifconfig|grep 'inet addr'|grep -v ':127'|sed -e " \
                "'s/.*addr:\([0-9.]*\) .*/\\1/'"
      ifconfig = @shell.query('IFCONFIG', ifc_cmd)

      ifconfig.each_line do |ip|
        ip.strip!
        ips[rfc1918?(ip)] << ip
      end
    end

    # Internal: Determine common libraries installed on the system.
    #
    # Returns nothing.
    def determine_libraries
      lib = @info[:lib] = {}

      libc_cmd = "ls -la `find /lib /usr/lib -name 'libc.so*'|head -1`|" \
                 "sed 's/.*-> //'"
      lib[:libc] = @shell.query('LIBC', libc_cmd)
      lib[:libc].gsub!(/^.*-|\.so$/, '')

      lib[:perl] = @shell.query('PERL', 'perl -e "print $^V;"')
      lib[:perl].gsub!(/^v([0-9.]*).*/, '\1')

      python_cmd = 'python -c "import sys; print sys.version" 2>/dev/null'
      lib[:python] = @shell.query('PYTHON', python_cmd)
      lib[:python].gsub!(/([0-9.]*).*/m, '\1')

      ruby_cmd = 'ruby -e "print RUBY_VERSION" 2>/dev/null'
      lib[:ruby] = @shell.query('RUBY', ruby_cmd)

      lib[:php] = @shell.query('PHP', 'php -v 2>/dev/null|head -1')
      lib[:php].gsub!(/^PHP ([0-9.]*).*/, '\1')
    end

    # Internal: Determine the total amount of memory on the target host, the
    # amount of memory in use, and the amount of swap space being used.
    #
    # Returns nothing.
    def determine_memory
      result = @info[:memory] = {}

      free_cmd = "free -m|awk '$1 ~ /Mem/ {print $2, $2-$6-$7}; $1 ~ /Swap/ " \
                 "{print $3}'|xargs"
      mem = @shell.query('MEMORY', free_cmd)
      total, used, swap = mem.split(/\s+/)

      result[:total] = total.to_i
      result[:mem_used] = used.to_i
      result[:swap_used] = swap.to_i
      result[:swapping?] = swqp.to_i > 0
    end

    # Internal: If the sysstat suite is installed on the target host, determine
    # the average amount of memory and swap used over whatever historical
    # period sar is able to represent.
    #
    # Returns nothing.
    def determine_memory_history
      result = @info[:memory_hist] = {}
      sar_cmd = "for l in $(find /var/log -name 'sa??');do sar -r -f $l|" \
                "grep Average;done|awk '{I+=1;TOT=$2+$3;CACHE+=$5+$6;"    \
                "FREE+=$2;SWAP+=$9;} END {CACHE=CACHE/I;FREE=FREE/I;"     \
                "SWAP=SWAP/I;print (TOT-(CACHE+FREE))/TOT*100,SWAP;}'"

      sar_location = @shell.query('SAR_LOCATION', 'which sar 2>/dev/null')
      if sar_location =~ /bin\//
        sar_usage = @shell.query('SAR', sar_cmd)

        if sar_usage =~/\d \d/
          mem, swap = sar_usage.split(/ /)
          result[:mem_used] = mem
          result[:swap_used] = swap
        end
      end
    end

    # Internal: Gather a list of all listening ports on the target host.
    #
    # Returns nothing.
    def determine_ports
      ports = @info[:ports] = {}

      netstat = @shell.query('NETSTAT', "netstat -ntlp|awk '{print $4, $NF}'")
      netstat.lines.each do |line|
        net, process = line.split(/\s+/, 2)
        process = process.split(/\//, 2)[1]
        net = net.gsub(/([0-9.:]+):([0-9]+)/, '\1 \2')
        net, port = net.split(/ /, 2)

        ports[net] ||= {}
        ports[net][port] = process
      end
    end

    # Internal: Gather a list of running processes on the target host.
    #
    # Returns nothing.
    def determine_processes
      procs = @shell.query('PROCESSES', 'ps aux')
      @info[:processes] = procs.gsub(/\r/, '').split(/\n/)
    end

    # Internal: Locate rsync on the target host.
    #
    # Returns nothing.
    def determine_rsync
      rsync = @shell.query('RSYNC', 'which rsync 2>/dev/null')

      if rsync.empty?
        rsync_cmd = '[ -f /root/.cloudflock/rsync ] && printf ' \
                    '"/root/.rackspace/rsync"'
        rsync = @shell.query('LOCAL_RSYNC', rsync_cmd)
        rsync = nil if rsync.empty?
      end

      @info[:rsync] = rsync
    end

    # Internal: Determine the architecture of the target host.
    #
    # Returns nothing.
    def determine_system_architecture
      @info[:arch] = @shell.query('UNAME', 'uname -m')
      @info[:arch].gsub!(/i\d86/, 'i386')
    end

    # Internal: Determine which web server, if any, is running on the target
    # host.  If the web server is supported, discover how many HTTP/HTTPS
    # domains are configured on the server.
    #
    # Returns nothing.
    def determine_web
      web = @info[:web] = {}
      netstat_cmd = 'netstat -ntlp|awk \'$4 ~ /:80$/ || $4 ~ /:443$/ ' \
                    '{sub (/^[^\/]*\//, ""); print $NF}\'|head -1'
      web[:binary] = @shell.query('WEB_NETSTAT', netstat_command)

      unless web[:binary].empty?
        if web[:binary] == 'httpd' || web[:binary] == 'apache2'
          version_cmd = "`which #{web[:binary]}` -v|grep version"
          web[:version] = @shell.query('WEB_VERSION', version_cmd)
          web[:version].gsub!(/.*version: /i, '')

          ctl_cmd = web[:binary] == 'httpd' ? 'apachectl' : 'apache2ctl'
          ctl_cmd << ' -S 2>&1'

          web_cmd = "#{ctl_cmd}|grep -vi 'default'|wc -l"
          hosts = @shell.query('WEB_HOSTS', web_cmd)

          ssl = hosts.lines.select { |line| line =~ /:443([^\d]|$)/ }
          http = hosts.lines - ssl
          web[:hosts_http] = http.length
          web[:hosts_https] = https.length
        end
      end
    end

    # Internal: Check for signs of running Plesk.
    #
    # Returns nothing.
    def warning_plesk
      unless @info[:processes].to_a.grep(/psa/i).empty?
        @warnings << "Server likely to be running Plesk"
      end
    end

    # Internal: Check for signs of running cPanel.
    #
    # Returns nothing.
    def warning_webmin
      unless @info[:processes].to_a.grep(/cpanel/i).empty?
        @warnings << "Server likely to be running cPanel"
      end
    end

    # Internal: Search for names of supported Linux distributions in a string
    # which may contain the name of the distribution currently installed on
    # the target host.
    #
    # Returns a String.
    def distro_name(str)
      SUPPORTED_DISTROS.select do |distro|
        Regexp.new(distro, Regexp::IGNORECASE).match(str)
      end[0].to_s
    end

    # Internal: Inspect a String which may contain information regarding the
    # version of the Linux distribution running on the target host.
    #
    # Returns nothing.
    def version_number(str)
      if str =~ /\d/
        str.gsub(/^[^\d]*/, '').gsub(/[^\d]*$/, '').gsub(/(\d*\.\d*).*/, '\1')
      else
        '-'
      end
    end

    # Internal: Determine if a v4 IP address belongs to a private (RFC 1918)
    # network.
    #
    # ip - String containing an IP.
    #
    # Returns either the symbol :public or :private.
    def rfc1918?(ip)
      return :private if Addrinfo.ip(ip).ipv4_private?

      :public
    end
  end
end; end; end
