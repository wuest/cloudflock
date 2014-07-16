module CloudFlock
  module App
    module Common
      class NoRsyncAvailable < StandardError; end
    end
  end

  module Remote
    class SSH
      class InvalidHostname  < StandardError; end
      class SSHCannotConnect < StandardError; end
    end
  end
end
