require 'cloudflock/target/servers'
require 'cloudflock/interface/cli/app/common/servers'

# Public: The Profile class provides the interface to produces profiles
# describing servers running Unix-like operating systems.
class CloudFlock::Interface::CLI::App::Servers::Profile
  include CloudFlock::Interface::CLI::App::Common::Servers
  include CloudFlock::Target::Servers
  CLI = CloudFlock::Interface::CLI::Console

  # Public: Begin Servers migration on the command line
  #
  # opts - Hash containing options mappings.
  def initialize(opts)
    resume = opts[:resume]
    source_host_def = define_source(opts[:config])
    source_host_ssh = CLI.spinner("Logging in to #{source_host_def[:host]}") do
      host_login(source_host_def)
    end

    profile = CLI.spinner("Checking source host") do
      profile = Profile.new(source_host_ssh)
      profile.build
      profile
    end
    platform = Platform::V2.new(profile[:cpe])

    memory = profile[:memory]
    memory_percent = memory[:mem_used].to_f / memory[:total] * 100
    swapping = memory[:swapping?]
    ftag = "#{CLI.bold}%15s#{CLI.reset}:"
    hist_mem = profile[:memory_hist][:mem_used]

    puts
    puts "#{CLI.bold}System Information#{CLI.reset}"
    puts "#{ftag} #{platform} (#{profile[:cpe]})" % "OS"
    puts "#{ftag} #{profile[:arch]}" % "Arch"
    puts "#{ftag} #{profile[:hostname]}" % "Hostname"
    puts

    puts "#{CLI.bold}CPU Statistics#{CLI.reset}"
    puts "#{ftag} %d" % ["CPU Count", profile[:cpu][:count]]
    puts "#{ftag} %d MHz" % ["CPU Speed", profile[:cpu][:speed]]
    puts 

    puts "#{CLI.bold}Memory Statistics#{CLI.reset}"
    puts "#{ftag} %d MiB" % ["Total RAM", memory[:total]]
    puts "#{ftag} %d MiB (%2.1f%%)" % ["RAM Used", memory[:mem_used],
                                         memory_percent]
    puts "#{ftag} %d MiB" % ["Swap Used", memory[:swap_used]] if swapping
    puts "#{ftag} %d%%" % ["Hist. RAM Used", hist_mem] unless hist_mem.nil?
    puts 

    puts "#{CLI.bold}Hard Disk Statistics#{CLI.reset}"
    puts "#{ftag} %2.1f GB" % ["Disk Used", profile[:disk]]
    puts

    puts "#{CLI.bold}System Statistics#{CLI.reset}"
    puts "#{ftag} #{profile[:io][:uptime]}" % "Uptime"
    puts "#{ftag} #{profile[:io][:wait]}" % "I/O Wait"
    puts

    puts "#{CLI.bold}IP Information#{CLI.reset}"
    puts "#{ftag} #{profile[:ip][:public].join(', ')}" % "Public"
    puts "#{ftag} #{profile[:ip][:private].join(', ')}" % "Private"
    puts

    puts "#{CLI.bold}MySQL Databases#{CLI.reset}"
    puts "#{ftag} #{profile[:db][:count]}" % "Number"
    puts "#{ftag} #{profile[:db][:size]}" % "Total Size"
    puts

    puts "#{CLI.bold}Libraries#{CLI.reset}"
    puts "#{ftag} #{profile[:lib][:libc]}" % "LIBC"
    puts "#{ftag} #{profile[:lib][:perl]}" % "Perl"
    puts "#{ftag} #{profile[:lib][:python]}" % "Python"
    puts "#{ftag} #{profile[:lib][:ruby]}" % "Ruby"
    puts "#{ftag} #{profile[:lib][:php]}" % "PHP"
    unless profile.warnings.empty?
      puts
      print CLI.red + CLI.bold
      profile.warnings.each { |warning| puts warning }
      print CLI.reset
    end

    source_host_ssh.logout!
  end
end
