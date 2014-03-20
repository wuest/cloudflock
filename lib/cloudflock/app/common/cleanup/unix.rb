require 'cloudflock/app/common/servers'

module CloudFlock; module App; module Common; class Cleanup
  # Public: The Unix module provides cleanup steps which are appropriate for
  # all Unix-like hosts.
  module Unix extend self
    # Public: Define pre-, during-, and post-chroot steps which will be
    # applicable to all Unix-like hosts.
    #
    # Returns nothing.
    def unix_cleanup
      pre_step 'mount proc -t proc /mnt/migration_target/proc'
      pre_step 'mount /dev /mnt/migration_target/dev -o rbind'
      pre_step 'mount /sys /mnt/migration_target/sys -o rbind'

      chroot_step 'find /var/run -type f -exec rm {} \;'

      post_step 'umount /mnt/migration_target/sys'
      post_step 'umount /mnt/migration_target/dev'
      post_step 'umount /mnt/migration_target/proc'
    end
  end
end; end; end; end
