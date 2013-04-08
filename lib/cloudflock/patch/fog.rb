require 'fog'
module Fog
  module Compute
    class RackspaceV2
      class Server
        # Place existing server into rescue mode, allowing for offline editing of configuration. The original server's disk is attached to a new instance of the same base image for a period of time to facilitate working within rescue mode.  The original server will be autom atically restored after 90 minutes.
        # @return [Boolean] returns true if call to put server in rescue mode returns success
        # @raise [Fog::Rackspace::Errors::NotFound] - HTTP 404
        # @raise [Fog::Rackspace::Errors::BadRequest] - HTTP 400
        # @raise [Fog::Rackspace::Errors::InternalServerError] - HTTP 500
        # @raise [Fog::Rackspace::Errors::ServiceError]
        # @note Rescue mode is only guaranteed to be active for 90 minutes.
        # @see http://docs.rackspace.com/servers/api/v2/cs-devguide/content/rescue_mode.html
        # @see #unrescue
        #
        # * Status Transition:
        #   * ACTIVE -> PREP_RESCUE -> RESCUE
        def rescue
          requires :identity
          data = service.rescue_server(identity)
          merge_attributes(data.body)
          self.state = RESCUE
          true
        end

        # Remove existing server from rescue mode.
        # @return [Boolean] returns true if call to remove server from rescue mode returns success
        # @raise [Fog::Rackspace::Errors::NotFound] - HTTP 404
        # @raise [Fog::Rackspace::Errors::BadRequest] - HTTP 400
        # @raise [Fog::Rackspace::Errors::InternalServerError] - HTTP 500
        # @raise [Fog::Rackspace::Errors::ServiceError]
        # @note Rescue mode is only guaranteed to be active for 90 minutes.
        # @see http://docs.rackspace.com/servers/api/v2/cs-devguide/content/exit_rescue_mode.html
        # @see #rescue
        #
        # * Status Transition:
        #   * RESCUE -> PREP_UNRESCUE -> ACTIVE
        def unrescue
          requires :identity
          service.unrescue_server(identity)
          self.state = ACTIVE
          true
        end
      end

      class Real
        # Puts server into rescue mode
        # @param [String] server_id id of server to rescue
        # @return [Excon::Response] response
        # @raise [Fog::Rackspace::Errors::NotFound] - HTTP 404
        # @raise [Fog::Rackspace::Errors::BadRequest] - HTTP 400
        # @raise [Fog::Rackspace::Errors::InternalServerError] - HTTP 500
        # @raise [Fog::Rackspace::Errors::ServiceError]
        # @note Rescue mode is only guaranteed to be active for 90 minutes.
        # @see http://docs.rackspace.com/servers/api/v2/cs-devguide/content/rescue_mode.html
        #
        # * Status Transition:
        #   * ACTIVE -> PREP_RESCUE -> RESCUE
        def rescue_server(server_id)
          data = {
            'rescue' => nil
          }

          request(
            :body => Fog::JSON.encode(data),
            :expects => [200],
            :method => 'POST',
            :path => "servers/#{server_id}/action"
          )
        end

        # Take server out of rescue mode
        # @param [String] server_id id of server
        # @return [Excon::Response] response
        # @raise [Fog::Rackspace::Errors::NotFound] - HTTP 404
        # @raise [Fog::Rackspace::Errors::BadRequest] - HTTP 400
        # @raise [Fog::Rackspace::Errors::InternalServerError] - HTTP 500
        # @raise [Fog::Rackspace::Errors::ServiceError]
        # @see http://docs.rackspace.com/servers/api/v2/cs-devguide/content/exit_rescue_mode.html
        #
        # * Status Transition:
        #   * RESCUE -> PREP_UNRESCUE -> ACTIVE
        def unrescue_server(server_id)
          data = {
            'unrescue' => nil
          }

          request(
            :body => Fog::JSON.encode(data),
            :expects => [202],
            :method => 'POST',
            :path => "servers/#{server_id}/action"
          )
        end
      end

      class Mock
        def rescue_server(server_id)
          server = self.data[:servers][server_id]
          server["status"] = "PREP_RESCUE"
          response(:status => 200)
        end

        def unrescue_server(server_id)
          server = self.data[:servers][server_id]
          server["status"] = "PREP_UNRESCUE"
          response(:status => 202)
        end
      end
    end
  end
end

