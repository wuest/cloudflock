require 'fog'
require 'console-glitter'
require 'cloudflock/app'

module CloudFlock; module App
  # Public: The Rackspace module provides common methods for CLI interaction
  # pertaining to interaction with the Rackspace API.
  module Rackspace
    include ConsoleGlitter
    # Public: Gather information necessary to manage Rackspace cloud assets via
    # API.
    #
    # Returns a Hash containing information necessary to establish an API
    # session.
    def define_rackspace_api
      {
        provider:           'rackspace',
        rackspace_username: UI.prompt('Rackspace Cloud Username'),
        rackspace_api_key:  UI.prompt('Rackspace Cloud API key'),
        rackspace_region:   define_rackspace_region
      }
    end

    # Public: Determine which Rackspace public endpoint should be used.
    #
    # Returns a String.
    def define_rackspace_region
      countries = [/^u[sk]$/i]
      region = UI.prompt('Account Region (us, uk)', valid_answers: countries)
      Fog::Rackspace.const_get(region.upcase + '_AUTH_ENDPOINT')
    end

    # Public: Wrap define_rackspace_service_region, specifying
    # 'cloudServersOpenStack' as the service type.
    #
    # api     - Authenticated Fog API instance.
    #
    # Returns a Hash.
    def define_rackspace_cloudservers_region(api)
      api.merge(define_rackspace_service_region(api, 'cloudServersOpenStack'))
    end
    
    # Public: Wrap define_rackspace_service_region, specifying 'cloudFiles' as
    # the service type.
    #
    # api     - Authenticated Fog API instance.
    #
    # Returns a Hash.
    def define_rackspace_files_region(api)
      api.merge(define_rackspace_service_region(api, 'cloudFiles'))
    end

    # Public: Have the user select from a list of regions available to their
    # Rackspace account.
    #
    # api     - Authenticated Fog API instance.
    # service - String describing the service to be used (e.g. 'cloudFiles',
    #           'cloudServersOpenStack').
    #
    # Returns a Hash containing a :rackspace_region => String mapping.
    def define_rackspace_service_region(api, service)
      identity = Fog::Identity.new(api)
      regions = identity.service_catalog.display_service_regions(service)
      regions = regions.split(', ').map { |e| e.gsub(/^:/, '') }

      region = UI.prompt("Target Region (#{regions.join(', ')})",
                         valid_answers: regions)
      { rackspace_region: region }
    end
  end
end; end
