require 'cloudflock/app/common/platform_action'

module CloudFlock; module App; module Common
  # Public: The Exclusions Class allows for building exclusions lists suitable
  # for migrating live hosts based upon the detected platform.
  class Exclusions < PlatformAction
    # Public: Initialize the internal state, then find suitable exclusions for
    # the detected platform.
    #
    # cpe - CPE object.
    def initialize(cpe)
      super

      find_exclusions
    end

    # Public: Add a location to the list of paths to exclude from a migration.
    #
    # location - String containing a path.
    #
    # Returns nothing.
    def exclude(location)
      exclusions << location
    end

    # Public: Return all exclusions separated by newlines.
    #
    # Returns a String.
    def to_s
      exclusions.join("\n")
    end

    private

    # Internal: Gets the internal Array of exclusions.  Initializes to an empy
    # Array if it doesn't exist.
    #
    # Returns an Array.
    def exclusions
      @collection[:exclude] ||= []
    end

    # Internal: Iterate through available modules for the current platform,
    # calling all methods available which end in '_exclusions'.
    #
    # Returns nothing.
    def find_exclusions
      load_each do |mod|
        extend mod

        mod.public_methods.select { |m| /_exclusions$/.match m }.each do |m|
          self.send(m)
        end
      end
    end
  end
end; end; end
