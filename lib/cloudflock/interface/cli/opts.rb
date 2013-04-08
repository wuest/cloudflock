require 'optparse'
Dir.glob(File.expand_path("../opts/*", __FILE__), &method(:require))

# Public: The CLI Opts module provides methods to abstract and simplify loading
# configuration information, parsing options and providing context to the
# application.
module CloudFlock::Interface::CLI::Opts extend self
  CONFIG_LOCATION="~/.flockrc"
  # Public: Open config files if applicable, overwriting default options with
  # configuration passed files first, then with any options supplied via the
  # command line.
  #
  # function - String or Symbol containing the name of the function to parse
  #            arguments for, if applicable. (default: '')
  #
  # Returns a Hash containing an option to value map.
  def parse(function = '')
    options = parse_config_file(CONFIG_LOCATION)

    argv = parse_argv(function)
    if argv[:config_file].kind_of?(String)
      options.merge(parse_config_file(argv[:config_file]))
    end

    options.merge(argv)
  end

  # Internal: Open and parse a given config file.
  #
  # file - String containing path to a configuration file which will be parsed.
  #
  # Returns a Hash containing option-value mappings.
  def parse_config_file(file)
    options = {}
    return options if file.nil?

    config_string = ""
    if File.exists?(File.expand_path(file))
      config_string = File.open(File.expand_path(file)).read
    end

    config_string.each_line do |line|
      line.gsub!(/#.*/, "").strip!
      next if line.empty?

      opt,value = line.split(/\s*/, 2)
      options[opt.to_sym] = value
    end

    options
  end

  # Internal: Parse and return options passed via the command line.
  #
  # function - String or Symbol containing the name of the function to parse
  #            arguments for.  This will cause the OptionParser to search for a
  #            argv_function name for the given name of the function.
  #
  # Returns a Hash containing an option to value map.
  def parse_argv(function)
    options = {}

    optparse = OptionParser.new do |opts|
      opts.on('-v', '--verbose', 'Be verbose') do
        options[:verbose] = true
      end

      opts.on('-c', '--config FILE', 'Load configuration saved from previous' +
                                     ' session (useful with -r)') do |file|
        unless File.exists?(File.expand_path(file))
          puts "Configuration file #{file} does not exist!  Exiting."
          exit
        end
        options[:config_file] = File.expand_path(file)
      end

      # Pull in extra options if applicable
      function = ("argv_" + function.to_s).to_sym
      if CloudFlock::Interface::CLI::Opts.respond_to?(function)
        CloudFlock::Interface::CLI::Opts.send(function, opts, options)
      end
    end
    optparse.parse!

    options
  end
end
