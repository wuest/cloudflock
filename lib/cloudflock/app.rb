require 'optparse'
require 'cloudflock'
require 'console-glitter'

module CloudFlock
  # Public: The App module provides any functionality that is expected to be
  # used by all CLI applications.
  module App extend self
    # Public: Parse options and expose global options which are expected to be
    # useful in any CLI application.
    #
    # options - Hash containing already-set options.
    #
    # Yields the OptionsParser object in use if a block is given.
    #
    # Returns a Hash.
    def parse_options(options = {})
      opts = OptionParser.new

      yield opts if block_given?

      opts.separator ''
      opts.separator 'Global Options:'

      opts.on('-c', '--config FILE', 'Specify configuration file') do |file|
        options[:config_file] = File.expand_path(file)
      end

      opts.on_tail('--version', 'Show Version Information') do
        puts "CloudFlock v#{CloudFlock::VERSION}"
        exit
      end

      opts.on_tail('-?', '--help', 'Show this Message') do
        puts opts
        exit
      end

      opts.parse!(ARGV)

      options
    rescue OptionParser::MissingArgument, OptionParser::InvalidOption => error
      puts error.message.capitalize
      puts
      ARGV.clear
      ARGV.unshift('-?')
      retry
    end
  end
end
