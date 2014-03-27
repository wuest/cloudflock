require 'optparse'
require 'cloudflock'
require 'console-glitter'

module CloudFlock
  # Public: The App module provides any functionality that is expected to be
  # used by all CLI applications.
  module App extend self
    include ConsoleGlitter

    # Public: Check if an option is set; return the value if so, otherwise
    # prompt the user for a response.
    #
    # options        - Hash containing options to test against.
    # name           - The key in the options Hash expected to contain the
    #                  response desired.
    # prompt         - Prompt to present to the user.
    # prompt_options - Options to pass along to ConsoleGlitter::UI#prompt.
    #                  (default: {})
    #
    # Returns the contents of the options[name] or else a String if
    # options[name] is nil.
    def check_option(options, name, prompt, prompt_options = {})
      return options[name] unless options[name].nil?

      options[name] = UI.prompt(prompt, prompt_options)
    end

    # Public: Check if an option is set; return the value if so, otherwise
    # prompt the user for a response.
    #
    # options        - Hash containing options to test against.
    # name           - The key in the options Hash expected to contain the
    #                  response desired.
    # prompt         - Prompt to present to the user.
    # prompt_options - Options to pass along to ConsoleGlitter::UI#prompt_yn.
    #                  (default: {})
    #
    # Returns true or false.
    def check_option_yn(options, name, prompt, prompt_options = {})
      return(options[name] ? true : false) unless options[name].nil?

      options[name] = UI.prompt_yn(prompt, prompt_options)
    end

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
