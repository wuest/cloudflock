module CloudFlock
  module Remote
    class SSH
      class InvalidHostname < StandardError; end
      class ConnectionFailed < StandardError; end
      class LoginFailed < StandardError; end
      class RootFailed < StandardError; end
    end
  end

  module Target
    module Servers
      module Migrate
        class LongRunFailed < StandardError; end
      end

      class Platform
        class ValueError < StandardError; end
        class MapUndefined < NameError; end
      end

      class Profile
      end
    end
  end
end
