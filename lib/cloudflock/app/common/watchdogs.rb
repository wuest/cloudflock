require 'console-glitter'
require 'cloudflock/app'
require 'cloudflock/remote/ssh'
require 'cloudflock/remote/ssh/watchdog'

module CloudFlock; module App
  # Public: The Watchdogs module provides commonly used watchdogs.
  module Watchdogs extend self
    # Public: Create a Watchdog which monitors the used disk space on a given
    # host.
    #
    # ssh  - SSH session which the Watchdog should monitor.
    # name - String describing the Watchdog.
    #
    # Returns a Watchdog.
    def used_space(ssh, name)
      CloudFlock::Remote::SSH::Watchdog.new(name, ssh, 'df', 60) do |df|
        lines = df.lines.select { |line| /^[^ ]*\s+\d+/.match line }
        lines.map { |line| line.split(/\s+/)[2].to_i }.reduce(&:+)
      end
    end

    # Public: Create a Watchdog which monitors the system load average on a
    # given host.
    #
    # ssh  - SSH session which the Watchdog should monitor.
    # name - String describing the Watchdog.
    #
    # Returns a Watchdog.
    def system_load(ssh, name)
      CloudFlock::Remote::SSH::Watchdog.new(name, ssh, 'uptime', 15) do |uptime|
        uptime.split(/\s+/)[-3].to_f
      end
    end

    # Public: Create a Watchdog which monitors the memory in use on a given
    # host.
    #
    # ssh  - SSH session which the Watchdog should monitor.
    # name - String describing the Watchdog.
    #
    # Returns a Watchdog.
    def utilized_memory(ssh, name)
      CloudFlock::Remote::SSH::Watchdog.new(name, ssh, 'free', 15) do |free|
        lines = free.lines.select { |line| /Mem/.match line }
        lines.map { |line| line.split(/\s+/)[3] }.first.to_i / 1024.0
      end
    end
  end
end; end
