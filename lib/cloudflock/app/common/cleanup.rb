require 'cloudflock/app/common/platform_action'

module CloudFlock; module App; module Common
  # Public: The Cleanup Class allows for building tasks leading up to, during
  # and following chrooting into a staged post-migration environment to perform
  # cleanup tasks.
  class Cleanup < PlatformAction
    # Public: Initialize the internal state, then find suitable tasks for the
    # detected platform.
    #
    # cpe - CPE object.
    def initialize(cpe)
      super

      define_steps
    end

    # Public: Define a step to be performed prior to chrooting.
    #
    # step - String containing a command to be performed.
    #
    # Returns nothing.
    def pre_step(step)
      pre << step
    end

    # Public: Define a step to be performed in a chroot environment.
    #
    # step - String containing a command to be performed.
    #
    # Returns nothing.
    def chroot_step(step)
      chroot << step
    end

    # Public: Define a step to be performed after leaving the chroot
    # environment.
    #
    # step - String containing a command to be performed.
    #
    # Returns nothing.
    def post_step(step)
      post << step
    end

    # Public: Return all pre-chroot steps separated by newlines.
    #
    # Returns a String.
    def pre_s
      pre.join("\n")
    end

    # Public: Return all chroot steps separated by newlines.
    #
    # Returns a String.
    def chroot_s
      chroot.join("\n")
    end

    # Public: Return all post-chroot steps separated by newlines.
    #
    # Returns a String.
    def post_s
      post.join("\n")
    end

    private

    # Internal: Gets the internal Array of pre-chroot steps.  Initializes to an
    # empy Array if it doesn't exist.
    #
    # Returns an Array.
    def pre
      @collection[:pre] ||= []
    end

    # Internal: Gets the internal Array of chroot environment steps.
    # Initializes to an empy Array if it doesn't exist.
    #
    # Returns an Array.
    def chroot
      @collection[:chroot] ||= []
    end

    # Internal: Gets the internal Array of post-chroot steps.  Initializes to
    # an empy Array if it doesn't exist.
    #
    # Returns an Array.
    def post
      @collection[:post] ||= []
    end

    # Internal: Iterate through available modules for the current platform,
    # calling all methods available which end in '_cleanup'.
    #
    # Returns nothing.
    def define_steps
      load_each do |mod|
        extend mod

        mod.public_methods.select { |m| /_cleanup$/.match m }.each do |m|
          self.send(m)
        end
      end
    end
  end
end; end; end
