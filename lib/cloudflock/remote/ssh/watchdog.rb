require 'cloudflock'
require 'net/ssh'
require 'thread'

module CloudFlock; module Remote; class SSH
  # The Watchdog Class allows for the creation of custom watchdogs to allow the
  # status of an ongoing migration as well as the health of the hosts involved
  # to be monitored.
  #
  # Examples
  #
  #   # Create a Watchdog to monitor system load, the state will be tracked as
  #   a float and updated every 15 seconds (roughly 3 refreshes by default.)
  #   # The state of the Watchdog can be accessed via the Watchdog#state method.
  #   system_load = Watchdog.new(ssh, 'uptime', 15) do |wait|
  #     wait.gsub(/^.*(\d+\.\d+).*$/, '\\1').to_f
  #   end
  #
  #   # Alerts can be created, so that action can be taken automatically.
  #   system_load.create_alarm('high_load') { |wait| wait > 10 }
  #   system_load.on_alarm('high_load') { |wait| puts "Load is #{wait}!"; exit }
  class Watchdog
    attr_reader :state
    attr_reader :name

    # Public: Create a new Watchdog to keep track of some aspect of a given
    # host's state.
    #
    # name     - String containing the watchdog's name.
    # ssh      - SSH session which the Watchdog should monitor.
    # command  - String to run periodically on the target SSH session to
    #            determine the host's state.
    # interval - Number of seconds to wait between command invocations.
    #            (default: 30)
    # block    - Optional block to be passed the results of the command to
    #            transform the data and make it more easily consumable.
    #            (default: identity function)
    def initialize(name, ssh, command, interval = 30, &block)
      @name      = name
      @ssh       = ssh
      @command   = command
      @interval  = interval
      @transform = block
      @thread    = start_thread
      @alarms    = {}
      @actions   = {}
    end

    # Public: Stop the Watchdog from running.
    #
    # Returns nothing.
    def stop
      thread.kill
    end

    # Public: Create a new named alarm, providing a predicate to indicate that
    # the alarm should be considered active.
    #
    # name  - Name for the alarm.
    # block - Block to be evaluated in order to determine if the alarm is
    #         active.  The block should accept one argument (the current state
    #         of the Watchdog).
    #
    # Returns nothing.
    def create_alarm(name, &block)
      alarms[name] = block
    end

    # Public: Define the action which should be taken when an alarm is
    # triggered.
    #
    # name  - Name of the alarm.
    # block - Block to be executed when an alarm is determined to be triggered.
    #         The block should accept one argument (the current state of the
    #         Watchdog).
    #
    # Returns nothing.
    def on_alarm(name, &block)
      actions[name] = block
    end

    # Public: Determine whether a given alarm is presently active.
    #
    # name  - Name of the alarm.
    #
    # Returns false if the alarm is not defined, or the result of the alarm
    # predicate otherwise.
    def alarm_active?(name)
      triggered = alarms[name].nil? ? false : alarms[name]
    end

    # Public: Return the state of all active alarms.
    #
    # Returns an Array of active alarms.
    def triggered_alarms
      alarms.select { |k,v| v[state] }.map(&:first)
    end

    private

    attr_reader :ssh, :command, :interval, :thread, :transform, :alarms
    attr_reader :actions
    attr_writer :state

    # Internal: Create a thread to periodically poll the server and determine
    # if any alerts should be considered active.
    #
    # Returns the newly created thread.
    def start_thread
      Thread.new do
        loop do
          result = ssh.query(command)
          state  = transform.nil? ? result : transform[result]

          respond_to_alarms
          sleep interval
        end
      end
    end

    # Internal: For each alert for which a triggered behavior exists, determine
    # if the alarm is considered fired.
    #
    # Returns nothing.
    def respond_to_alarms
      triggered_alarms.each { |key| actions[key].call if actions[key] }
    end
  end
end; end; end
