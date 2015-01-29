module CloudFlock
  module Log
    private

    # Internal: If a logger exists, commit a string to the log.  Otherwise, do
    # nothing.
    #
    # string - String to be logged.
    # prefix - String to prefix the logged text.  (default: '')
    # level  - Symbol specifying the log level to be reported under.
    #          (default: :debug)
    #
    # Returns a String containing any output of the command run.
    def log(string, prefix = '', level = :debug)
      return string unless logger

      logger.public_send(level, prefix + string.inspect.gsub(/^"|"$/, ''))
      string
    end
  end
end
