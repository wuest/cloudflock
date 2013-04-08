module CloudFlock::Interface::CLI::Opts extend self
  # Internal: Extend the Opts module to provide options specific to the servers
  # migration CLI utility.
  #
  # opts    - OptionParser object to which to add options.
  # options - Hash containing options flags and settings for the application.
  #
  # Returns nothing.
  def argv_servers(opts, options)
    opts.on('-o', '--opencloud', 'Perform an Open Cloud Servers migration') do
      options[:function] = :opencloud
    end
    opts.on('-s', '--servers', 'Perform a Cloud Servers migration') do
      options[:function] = :servers
    end
    opts.on('-r', '--resume', 'Resume a migration') do
      options[:resume] = true
    end
  end
end
