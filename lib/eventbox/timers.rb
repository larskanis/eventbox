class Eventbox
  # Simple timer services for Eventboxes
  #
  # This module can be included into Eventbox classes to add simple timer functions.
  #
  #   class MyBox < Eventbox
  #     include Eventbox::Timers
  #
  #     async_call def init
  #       super # make sure Timers.init is called
  #       timers_after(1) do
  #         puts "one second elapsed"
  #       end
  #     end
  #   end
  #
  # The main functions are timers_after and timers_every.
  # They schedule asynchronous calls to the given block:
  #   timers_after(3) do
  #     # executed in 3 seconds
  #   end
  #
  #   timers_every(3) do
  #     # executed every 3 seconds
  #   end
  #
  # Both functions return an Alarm object which can be used to cancel the alarm through timers_cancel.
  #
  # timers_after, timers_every and timers_cancel can be used within the class, in actions and from external.
  module Timers
    class Reload < RuntimeError
    end

    class Alarm
      include Comparable

      def initialize(ts, &block)
        @timestamp = ts
        @block = block
      end

      def <=>(other)
        @timestamp <=> other
      end

      attr_reader :timestamp
    end

    class OneTimeAlarm < Alarm
      def fire_then_repeat?(now=Time.now)
        @block.call
        false
      end
    end

    class RepeatedAlarm < Alarm
      def initialize(ts, every_seconds, &block)
        super(ts, &block)
        @every_seconds = every_seconds
      end

      def fire_then_repeat?(now=Time.now)
        @block.call
        @timestamp = now + @every_seconds
        true
      end
    end

    extend Boxable

    private async_call def init(*args)
      super
      @timers_alarms = []
      @timers_action = timers_start_clock
    end

    # @private
    private action def timers_start_clock
      loop do
        begin
          interval = timers_next_timestamp&.-(Time.now)
          Thread.handle_interrupt(Reload => :on_blocking) do
            if interval.nil?
              sleep
            elsif interval > 0.0
              sleep(interval)
            end
          end
        rescue Reload
        else
          timers_fire
        end
      end
    end

    sync_call def timers_after(seconds, now=Time.now, &block)
      a = OneTimeAlarm.new(now + seconds, &block)
      timers_add_alarm(a)
      a
    end

    sync_call def timers_every(seconds, now=Time.now, &block)
      a = RepeatedAlarm.new(now + seconds, seconds, &block)
      timers_add_alarm(a)
      a
    end

    sync_call def timers_cancel(alarm)
      i = @timers_alarms.index(alarm)
      if i
        @timers_alarms.slice!(i)
        if i == @timers_alarms.size
          @timers_action.raise(Reload) unless @timers_action.current?
        end
      end
    end

    # @private
    private def timers_add_alarm(alarm)
      i = @timers_alarms.bsearch_index {|t| t <= alarm }
      if i
        @timers_alarms[i, 0] = alarm
      else
        @timers_alarms << alarm
        @timers_action.raise(Reload) unless @timers_action.current?
      end
    end

    # @private
    private sync_call def timers_next_timestamp
      @timers_alarms[-1]&.timestamp
    end

    # @private
    private sync_call def timers_fire(now=Time.now)
      i = @timers_alarms.bsearch_index {|t| t <= now }
      if i
        due_alarms = @timers_alarms.slice!(i .. -1)
        due_alarms.reverse_each do |a|
          if a.fire_then_repeat?(now)
            timers_add_alarm(a)
          end
        end
      end
    end
  end
end
