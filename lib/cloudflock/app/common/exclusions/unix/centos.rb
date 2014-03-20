module CloudFlock; module App; module Common; class Exclusions; module Unix
  # Public: The Centos module provides exclusions which are expected to be
  # appropriate for CentOS hosts.
  module Centos extend self
    # Public: Exclude paths which are expected to be appropriate for CentOS
    # hosts.
    #
    # Returns nothing.
    def centos_exclusions
      exclude '/etc/yum.repos.d/'
      exclude '/usr/lib/yum-plugins'
      exclude '/etc/yum.conf'
      exclude '/etc/yum'
      exclude '/etc/yum.repos.d'
      exclude '/etc/sysconfig/iptables'
    end
  end
end; end; end; end; end
