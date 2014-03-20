require 'cloudflock/remote/ssh'
require 'cpe'

module CloudFlock; module Task
  class ServerProfile
    # Public: List of linux distributions supported by CloudFlock
    DISTRO_NAMES = %w{Arch CentOS Debian Gentoo Scientific SUSE Ubuntu RedHat}

    # Internal: Sections of the profile.
    Section = Struct.new(:title, :entries)

    # Internal: Individual entries for profiled data.
    Entry = Struct.new(:name, :values)

    attr_reader :cpe
    attr_reader :warnings
    attr_reader :process_list

    # Public: Initialize the Profile object.
    #
    # shell   - An SSH object which is open to the host which will be profiled.
    def initialize(shell)
      @shell    = shell
      @cpe      = nil
      @warnings = []
      @info     = []

      build
    end

    # Public: Return server information and warnings as a Hash.
    #
    # Returns a Hash.
    def to_hash
      { info: @info, warnings: @warnings }
    end

    # Public: Select from the info Array, passing Section titles to the block
    # provided and returning a list of entries contained within matching
    # sections.
    #
    # Examples
    #
    #   profile.select { |title| title == 'Memory Statistics' }
    #   # => [...]
    #
    #   profile.select { |title| /Memory/.match title }
    #   # => [...]
    #
    # Yields titles of Section structs (Strings).
    #
    # Returns an Array of Entry structs.
    def select(&block)
      sections = @info.select { |section| block.call(section.title) }
      sections.map! { |section| section.entries }
      sections.flatten
    end

    # Public: Select values from within entries, specifying both section and
    # entry names.
    #
    # section - String or Regexp specifying the section name.
    # name    - String or Regexp specifying the desired entry's name.
    #
    # Examples
    #
    #   profile.select_entries('Memory Statistics', 'Used RAM')
    #   # => [...]
    #
    #   profile.select_entries(/Memory/, 'Used RAM')
    #   # => [...]
    #
    # Returns an Array of Strings.
    def select_entries(section, name)
      entries = select { |header| header.match section }
      filtered = entries.select { |entry| name.match entry.name }
      filtered.map(&:values)
    end

    private

    # Internal: Build the profile by calling all methods which begin with
    # 'build_' and 'warning_'.
    #
    # Returns nothing.
    def build
      private_methods.select { |x| x =~ /^build_/ }.each do |method|
        @info.push self.send(method)
      end
      private_methods.select { |x| x =~ /^warning_/ }.each do |method|
        self.send(method)
      end
    end

    # Internal: Filter methods by name, creating a new Section struct in which
    # to hold results.
    #
    # name          - Name to give to the new Section struct.
    # method_filter - Regexp against which to match method names.
    #
    # Examples
    #
    #   filter_tasks('System Information', /^determine_system_/)
    #
    # Returns a Section struct.
    def filter_tasks(name, method_filter)
      section = Section.new(name)
      tasks = private_methods.select { |task| method_filter.match(task) }
      section.entries = tasks.map do |method|
        self.send(method)
      end

      section
    end

    # Internal: Build the "System Information" Entries.
    #
    # Returns nothing.
    def build_system
      filter_tasks('System Information', /^determine_system_/)
    end

    # Internal: Build the "CPU Statistics" Entries.
    #
    # Returns nothing.
    def build_cpu
      filter_tasks('CPU Statistics', /^determine_cpu_/)
    end

    # Internal: Build the "Memory Statistics" Entries.
    #
    # Returns nothing.
    def build_memory
      filter_tasks('Memory Statistics', /^determine_memory_/)
    end

    # Internal: Build the "System Usage" Entries.
    #
    # Returns nothing.
    def build_load
      filter_tasks('System Usage', /^determine_load_/)
    end

    # Internal: Build the "Storage Statistics" Entries.
    #
    # Returns nothing.
    def build_storage
      filter_tasks('Storage Statistics', /^determine_storage_/)
    end

    # Internal: Build the "IP Usage" Entries.
    #
    # Returns nothing.
    def build_network
      filter_tasks('IP Usage', /^determine_network_/)
    end

    # Internal: Build the "Installed Libraries" Entries.
    #
    # Returns nothing.
    def build_library
      filter_tasks('Installed Libraries', /^determine_library_/)
    end

    # Internal: Build the "System Services" Entries.
    #
    # Returns nothing.
    def build_services
      filter_tasks('System Services', /^determine_services_/)
    end

    # Internal: Attempt to determine which linux distribution the target host
    # is running.
    #
    # Returns an Entry struct.
    def determine_system_distribution
      set_system_cpe
      vendor = cpe.vendor
      product = cpe.product.gsub(/_/, ' ').capitalize
      version = cpe.version
      platform = [vendor, product, version].join(' ')

      warn("Unable to determine the target host's platform") if vendor.empty?

      Entry.new('OS', platform + " (#{@cpe.to_s})")
    end

    # Internal: Determine the architecture of the target host.
    #
    # Returns an Entry struct.
    def determine_system_architecture
      arch = query('uname -m').gsub(/i\d86/, 'x86')

      warn("Unable to determine target architecture") if arch.empty?

      Entry.new('Arch', arch)
    end

    # Internal: Determine the hostname of the target host.
    #
    # Returns an Entry struct.
    def determine_system_hostname
      hostname = query('hostname')
      Entry.new('Hostname', hostname)
    end

    # Internal: Gather a list of running processes on the target host.
    #
    # Returns an Entry struct.
    def determine_system_process_list
      procs = query('ps aux')
      @process_list = procs.lines

      Entry.new('Process Count', procs.lines.to_a.length)
    end

    # Internal: Determine the number of CPU cores on the target host.
    #
    # Returns an Entry struct.
    def determine_cpu_count
      lscpu = query('lscpu')

      # If lscpu is available, it gives the best information.  Otherwise, fall
      # back to sysctl which should handle the vast majority of Unix systems.
      if /CPUs?/.match(lscpu)
        count = lscpu.lines.select { |l| l =~ /CPU\(s\)/ }[0].gsub(/.* /, '')
        count = count
      else
        # hw.ncpu covers BSD hosts (the primary case when lscpu(1) is not
        # present on a system).  kernel.sched_domain covers linux hosts which
        # do not have have lscpu installed.
        #
        # Example expected outputs on a 2-core smp system:
        #   $ sysctl hw.ncpu
        #   hw.ncpu: 2
        #
        #   $ sysctl kernel.sched_domain
        #   kernel.sched_domain.cpu0.domain0.busy_factor = 64
        #   ...
        #   kernel.sched_domain.cpu1.domain1.wake_idx = 0
        sysctl = query('sysctl hw.ncpu || sysctl kernel.sched_domain')
        if /hw\.ncpu: /.match sysctl
          count = sysctl.gsub(/.*(\d)/, '\\1').to_i
        else
          sysctl = sysctl.lines.select { |line| /cpu\.?\d+/.match(line) }
          sysctl.map! { |line| line.gsub(/.*(cpu).*?(\d*).*/m, '\\1\\2') }
          count = sysctl.uniq.length
        end
      end

      warn("Unable to determine target CPU count") if count.to_i < 1

      Entry.new('CPU Count', count.to_i)
    end

    # Internal: Determine the CPU model on the target host.
    #
    # Returns an Entry struct.
    def determine_cpu_model
      lscpu = query('lscpu').lines.select { |l| l =~ /^model name/i }
      if lscpu.empty?
        cpuinfo = query('cat /proc/cpuinfo')
        model = cpuinfo.lines.select { |l| l =~ /model name/i }
        model = model[0].to_s.strip.gsub(/.*: */, '')
      else
        model = lscpu[0].strip.gsub(/.* /, '')
      end

      warn("Unable to determine target CPU model") if model.empty?

      Entry.new('Processor Model', model)
    end

    # Internal: Determine the total amount of memory on the target host.
    #
    # Returns an Entry struct.
    def determine_memory_total
      mem = query('free -m')
      if /^Mem/.match(mem)
        total = mem.lines.select { |l| l =~ /^Mem/ }.first.split(/\s+/)[1]
      else
        total = 0
        warn('Unable to determine target Memory')
      end
      Entry.new('Total RAM', "#{total} MiB")
    end

    # Internal: Determine the total amount of wired memory on the target host.
    #
    # Returns an Entry struct.
    def determine_memory_wired
      mem = query('free -m')
      if /^Mem/.match(mem)
        mem = mem.lines.select { |l| l =~ /^Mem/ }.first
        mem = mem.split(/\s+/).map(&:to_i)
        total = mem[1]
        used = total - mem[3..-1].reduce(&:+)
        used = sprintf("%#{total.to_s.length}d", used)
        percent = ((used.to_f / total) * 100).to_i
      else
        used = 0
        percent = 0
      end

      Entry.new('Used RAM', "#{used} MiB (#{percent}%)")
    end

    # Internal: Determine the total amount of swap used on the target host.
    #
    # Returns an Entry struct.
    def determine_memory_swap
      mem = query('free -m')
      if /^Swap/.match(mem)
        mem = mem.lines.select { |l| l =~ /^Swap/ }.first
        total, used = mem.split(/\s+/).map(&:to_i)[1..2]
        used = sprintf("%#{total.to_s.length}d", used)
        percent = ((used.to_f / total) * 100).to_i

        warn('Host is swapping') if percent > 0
      else
        used = percent = 0
        warn('Unable to enumerate swap')
      end

      Entry.new('Used Swap', "#{used} MiB (#{percent}%)")
    rescue ZeroDivisionError, FloatDomainError
      Entry.new('Used Swap', 'No swap configured')
    end

    # Internal: If the sysstat suite is installed on the target host, determine
    # the average amount of memory used over whatever historical period sar is
    # able to represent.
    #
    # Returns an Entry struct.
    def determine_memory_usage_historical_average
      sar_location = query('which sar')
      usage = ''

      if sar_location =~ /bin\//
        sar_cmd = "for l in $(find /var/log -name 'sa??');do sar -r -f $l|" \
                  "grep Average;done|awk '{I+=1;TOT=$2+$3;CACHE+=$5+$6;"    \
                  "FREE+=$2;} END {CACHE=CACHE/I;FREE=FREE/I;"              \
                  "print (TOT-(CACHE+FREE))/TOT*100;}'"

        usage = query(sar_cmd)
      end
      usage = '' unless usage =~ /\d/

      warn('No historical usage information available') if usage.empty?

      Entry.new('Average Used', usage)
    end

    # Internal: If the sysstat suite is installed on the target host, determine
    # the average amount of swap used over whatever historical period sar is
    # able to represent.
    #
    # Returns an Entry struct.
    def determine_memory_swap_historical_average
      sar_location = query('which sar 2>/dev/null')
      usage = ''

      if sar_location =~ /bin\//
        sar_cmd = "for l in $(find /var/log -name 'sa??');do sar -r -f $l|" \
                  "grep Average;done|awk '{I+=1;;SWAP+=$9;} END "           \
                  "{SWAP=SWAP/I;print SWAP;}'"

        usage = query(sar_cmd)
      end
      usage = '' unless usage =~ /\d/

      Entry.new('Average Swap', usage)
    end

    # Internal: Determine the amount of time the target host has been running.
    #
    # Returns an Entry struct.
    def determine_load_uptime
      up = query('uptime')
      up.gsub!(/.* up([^,]*),.*/, '\\1')

      Entry.new('Uptime', up.strip)
    end

    # Internal: Determine the load averages on the target host.
    #
    # Returns an Entry struct.
    def determine_load_average
      avg = query('uptime')
      avg.gsub!(/^.* load averages?: |,.*$/i, '')

      warn('System is under heavy load') if avg.to_i > 10

      Entry.new('Load Average', avg)
    end

    # Internal: If the sysstat suite is installed on the target host, determine
    # the amount of historical IO activity on the target host.
    #
    # Returns an Entry struct.
    def determine_load_iowait
      iostat = query('iostat').lines.to_a[3].to_s.strip.split(/\s+/)[3]
      wait = iostat.to_f

      warn('Cannot determine IO Wait') if iostat.to_s.empty?
      warn('IO Wait is high') if wait > 10

      Entry.new('IO Wait', wait)
    end

    # Internal: Determine the amount of disk space in use on the target host.
    #
    # Returns an Entry struct.
    def determine_storage_disk_usage
      mounts = query('df').lines.select do |line|
        fs, blocks, _ = line.split(/\s+/, 3)
        /^\/dev/.match(fs) || blocks.to_i > 10000000
      end

      usage = mounts.reduce(0) do |collector, mount|
        collector + mount.split(/\s+/, 4)[2].to_i
      end

      usage = sprintf('%.1f', usage.to_f / 1000**2)

      warn('Unable to find meaningful mounts') if mounts.empty?
      warn('Unable to determine disk usage') if usage.to_f < 1

      Entry.new('Disk Usage', "#{usage} GB")
    end

    # Internal: Determine public IPv4 addresses in use by the target host.
    #
    # Returns an Entry struct.
    def determine_network_public_v4_ips
      addresses = list_v4_ips
      addresses.reject! { |ip| rfc1918?(ip) }

      Entry.new('Public IPs', addresses.sort.join(', '))
    end

    # Internal: Determine private IPv4 addresses in use by the target host.
    #
    # Returns an Entry struct.
    def determine_network_private_v4_ips
      addresses = list_v4_ips
      addresses.select! { |ip| rfc1918?(ip) }

      Entry.new('Private IPs', addresses.sort.join(', '))
    end

    # Internal: Determine which perl version (if any) is installed on the
    # target host.
    #
    # Returns an Entry struct.
    def determine_library_perl
      perl = query("perl -e 'print $^V;'")
      perl.gsub!(/^v([0-9.]*).*/, '\1')
      perl = '' unless /[0-9]/.match(perl)

      Entry.new('Perl', perl)
    end

    # Internal: Determine which python version (if any) is installed on the
    # target host.
    #
    # Returns an Entry struct.
    def determine_library_python
      python = query('python -c "import sys; print sys.version"')
      python.gsub!(/([0-9.]*).*/m, '\1')
      python = '' unless /\d/.match(python)

      Entry.new('Python', python)
    end

    # Internal: Determine which ruby version (if any) is installed on the
    # target host.
    #
    # Returns an Entry struct.
    def determine_library_ruby
      ruby = query('ruby -e "print RUBY_VERSION"')
      ruby = '' unless /\d/.match(ruby)

      Entry.new('Ruby', ruby)
    end

    # Internal: Determine which php version (if any) is installed on the target
    # host.
    #
    # Returns an Entry struct.
    def determine_library_php
      php = query('php -v').lines.to_a[0].to_s
      php.gsub!(/^PHP ([0-9.]*).*/, '\1')
      php = '' unless /\d/.match(php)

      Entry.new('PHP', php)
    end

    # Internal: Gather a list of all listening ports on the target host.
    #
    # Returns nothing.
    def determine_services_ports
      netstat = as_root('netstat -untlp')
      netstat = netstat.lines.select { |line| /^[tu][cd]p/.match(line) }
      netstat.map! { |line| line.split(/\s+/) }

      addresses = netstat.map { |row| row[3].gsub(/:[^:]*$/, '') }.uniq.sort
      netstat.map! do |row|
        port = row[3].gsub(/.*:/, '')
        pid = row[-1].gsub(/.*\//, '')
        " " * 16 + "% 6d %s" % [port, pid]
      end
      netstat.uniq!
      netstat.sort! { |x,y| x.to_i <=> y.to_i }

      warn('Cannot enumerate listening ports') if netstat.empty?

      netstat[0] = netstat[0].to_s[16..-1]
      Entry.new('Listening Ports', "#{netstat.join("\n")}")
    end

    # Internal: Check for signs of running control panels.
    #
    # Returns nothing.
    def warning_control_panels
      if @process_list.grep(/psa/i).any?
        warn('Server likely to be running Plesk')
      end
      if @process_list.grep(/cpanel/i).any?
        warn('Server likely to be running cPanel')
      end
    end

    # Internal: Enumerate v4 IPs on the host.
    #
    # Returns an Array of IPv4 addresses outside of 127/8
    def list_v4_ips
      addresses = query('/sbin/ifconfig').lines.select do |line|
        /inet[^6]/.match(line)
      end
      addresses.map! { |ip| ip.split(/\s+/).grep(/(?:\d+\.){3}\d+/)[0] }
      addresses.map! { |ip| ip.gsub(/[^\d]*((?:\d+\.){3}\d+)[^\d]*/, '\\1')}
      addresses.reject! { |ip| /127(\.\d+){3}/.match(ip) }
    end

    # Internal: Wrap SSH#query
    #
    # args - Globbed args to pass to SSH object
    #
    # Returns a String
    def query(*args)
      @shell.query(*args)
    end

    # Internal: Wrap SSH#as_root
    #
    # args - Globbed args to pass to SSH object
    #
    # Returns a String
    def as_root(*args)
      @shell.as_root(*args)
    end

    # Internal: Add a warning to the list of warnings encountered.
    #
    # warning - String containing warning text.
    #
    # Returns nothing.
    def warn(warning)
      @warnings.push warning
    end

    # Internal: Determine and set CPE representative of the running system.
    # Resort to a best guess if this cannot be reliably accomplished.
    #
    # Sets @cpe.
    #
    # Returns nothing.
    def set_system_cpe
      # Some distros ship with a file containing the CPE for their platform;
      # this should be used if at all possible.
      release = query('cat /etc/system-release-cpe')
      begin
        cpe = CPE.parse(release)
        cpe.version.gsub!(/[^0-9.]/, '')
        @cpe = cpe
        return
      rescue ArgumentError
      end

      cpe = CPE.new(part: CPE::OS)

      # Depend on the reported kernel name for product name
      cpe.product = query('uname -s')

      # Depend on /etc/issue if it's available
      issue = query('cat /etc/issue')
      cpe.vendor = distro_name(issue)

      # If /etc/issue fails, resort to looking any release/version file
      if cpe.vendor.empty?
        release = query("grep -h '^ID=' /etc/*[_-][rv]e[lr]*").lines.first
        cpe.vendor = distro_name(release)
      end

      # Fall back to depending on the OS reported by uname if all else fails
      cpe.vendor = query('uname -o') if cpe.vendor.empty?

      # Version number will be determined from /etc/issue
      cpe.version = version_number(issue)

      # If Version is not represented, fall back to kernel reported version
      cpe.version = version_number(query('uname -r')) if cpe.version.empty?
      @cpe = cpe
    end

    # Internal: Search for nicely formatted names of Linux distributions in a
    # string which may contain the name of the distribution currently running
    # on the target host.  If multiple matches exist, resort to the first one.
    #
    # Returns a String.
    def distro_name(str)
      matches = DISTRO_NAMES.select do |distro|
        Regexp.new(distro, Regexp::IGNORECASE).match(str)
      end
      matches.first.to_s
    end

    # Internal: Inspect a String which may contain a version number.  Sanitize
    # the version number, removing any extraneous information.
    #
    # Returns a String.
    def version_number(str)
      if str =~ /\d/
        str.gsub(/^[^\d]*/, '').gsub(/[^\d]*$/, '').gsub(/(\d*\.\d*).*/, '\1')
      else
        ''
      end
    end

    # Internal: Determine if a v4 IP address belongs to a private (RFC 1918)
    # network.
    #
    # ip - String containing an IP.
    #
    # Returns true if the IP falls within the private range, false otherwise.
    def rfc1918?(ip)
      octets = ip.split(/\./)
      if octets[0] == '10' || (octets[0] == '192' && octets[1] == '168')
        return true
      elsif octets[0] == '172' && (16..31).include?(octets[1].to_i)
        return true
      end

      false
    end
  end
end; end
