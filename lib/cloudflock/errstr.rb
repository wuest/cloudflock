module CloudFlock
  module App
    module Common
      module Errstr
        NO_RSYNC = 'Cannot find rsync on the destination host'
      end
    end
  end

  module Remote
    class SSH
      module Errstr
        NOHOST        = 'No host specified'
        INVALID_HOST  = 'Unable to look up host: %s'
      end
    end
  end

  module Target
    module Servers
      class Profile
        NOT_SSH = 'SSH session expected'
      end

      class Platform
        NOT_CPE        = 'Expected a CPE object'
        CPE_INCOMPLETE = 'CPE must contain at least vendor and version'
      end
    end
  end
end
