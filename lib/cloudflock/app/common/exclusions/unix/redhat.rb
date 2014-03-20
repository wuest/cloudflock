module CloudFlock; module App; module Common; class Exclusions; module Unix
  # Public: The Redhat module provides exclusions which are expected to be
  # appropriate for Redhat hosts.
  module Redhat extend self
    # Public: Exclude paths which are expected to be appropriate for RedHat
    # hosts.
    #
    # Returns nothing.
    def redhat_exclusions
      exclude '/etc/yum.repos.d/'
      exclude '/usr/lib/yum-plugins'
      exclude '/etc/yum.conf'
      exclude '/etc/yum'
      exclude '/etc/yum.repos.d'
      exclude '/etc/sysconfig/iptables'
    end
  end
end; end; end; end; end
