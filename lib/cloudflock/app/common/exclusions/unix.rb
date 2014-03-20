require 'cloudflock/app/common/servers'

module CloudFlock; module App; module Common; class Exclusions
  # Public: The Unix module provides exclusions which are expected to be
  # appropriate for all Unix-like hosts.
  module Unix extend self
    # Public: Exclude paths which are expected to be appropriate for all
    # Unix-like hosts.
    #
    # Returns nothing.
    def unix_exclusions
      exclude '/boot'
      exclude '/dev'
      exclude '/etc/fstab'
      exclude '/etc/hosts'
      exclude '/etc/init.d/nova-agent*'
      exclude '/etc/driveclient'
      exclude '/etc/initramfs-tools'
      exclude '/etc/issue'
      exclude '/etc/issue.net'
      exclude '/etc/lvm'
      exclude '/etc/mdadm*'
      exclude '/etc/mtab'
      exclude '/etc/mod*'
      exclude '/etc/network/'
      exclude '/etc/network.d/*'
      exclude '/etc/networks'
      exclude '/etc/rc3.d/S99Galaxy'
      exclude '/etc/resolv.conf'
      exclude '/etc/sysconfig/network'
      exclude '/etc/sysconfig/network-scripts/*'
      exclude '/etc/system-release'
      exclude '/etc/system-release-cpe'
      exclude '/etc/udev'
      exclude '/etc/prelink*'
      exclude '/etc/rc.conf'
      exclude '/etc/conf.d/net'
      exclude '/lib/init/rw'
      exclude '/lib/firmware'
      exclude '/lib/modules'
      exclude '/lib/udev'
      exclude '/root/.rackspace'
      exclude '/mnt'
      exclude '/net'
      exclude '/opt/galaxy/'
      exclude '/proc'
      exclude '/sys'
      exclude '/tmp'
      exclude '/usr/sbin/nova-agent*'
      exclude '/usr/share/initramfs-tools'
      exclude '/usr/share/nova-agent*'
      exclude '/var/cache/yum/*'
      exclude '/var/lib/initramfs-tools'
      exclude '/var/lock'
      exclude '/var/log'
    end
  end
end; end; end; end
