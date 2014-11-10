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
        lines = df.lines.select { |line| /^[^ ]*(?:\s+\d+){2,}/.match line }
        total = lines.map { |line| line.split(/\s+/)[1].to_i }.reduce(&:+)
        used  = lines.map { |line| line.split(/\s+/)[2].to_i }.reduce(&:+)
        used.to_f / total
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
        lines = free.lines.select { |line| /Swap/.match line }
        total,used = lines.empty? ? [0,0] : lines.map(&:to_f)[1..2]
        total > 0 ? free / total : 0.0
      end
    end

    # Public: Set up a default alert for if free space on the host falls below
    # 5%, killing a given thread if it reaches that threshhold.
    #
    # watchdog  - Watchdog to which the alarm should be added.
    # thread    - Thread to kill if the alarm fires.
    #
    # Returns nothing.
    def set_alarm_used_space(watchdog, thread)
      watchdog.create_alarm('out_of_space') { |space| space > 0.95 }
      watchdog.on_alarm('out_of_space')     { |space| thread.kill }
    end

    # Public: Set up a default alert for if the system load is >10, killing a
    # given thread if it reaches that threshhold.
    #
    # watchdog  - Watchdog to which the alarm should be added.
    # thread    - Thread to kill if the alarm fires.
    #
    # Returns nothing.
    def set_alarm_system_load(watchdog, thread)
      watchdog.create_alarm('load_too_high') { |waitq| waitq > 10 }
      watchdog.on_alarm('load_too_high')     { |waitq| thread.kill }
    end

    # Public: Set up a default alert for when swap used is > 25%, killing a
    # given thread if it reaches that threshhold.
    #
    # watchdog  - Watchdog to which the alarm should be added.
    # thread    - Thread to kill if the alarm fires.
    #
    # Returns nothing.
    def set_alarm_utilized_memory(watchdog, thread)
      watchdog.create_alarm('swapping') { |swap| swap > 0.25 }
      watchdog.on_alarm('swapping')     { |swap| thread.kill }
    end
  end
end; end
