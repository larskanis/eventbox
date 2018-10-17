class Eventbox
  # Simple timer services for Eventboxes
  #
  # This module can be included into Eventbox classes to add simple timer functions.
  #
  #   class MyBox < Eventbox
  #     include Eventbox::Timer
  #
  #     async_call def init
  #       super   # make sure Timer#init is called
  #       timer_after(1) do
  #         puts "one second elapsed"
  #       end
  #     end
  #   end
  #
  # The main functions are timer_after and timer_every.
  # They schedule asynchronous calls to the given block:
  #   timer_after(3) do
  #     # executed once after 3 seconds
  #   end
  #
  #   timer_every(3) do
  #     # executed repeatedly every 3 seconds
  #   end
  #
  # Both functions return an Alarm object which can be used to cancel the alarm through timer_cancel.
  #
  # timer_after, timer_every and timer_cancel can be used within the class, in actions and from external.
  module Timer
    class Reload < RuntimeError
    end
    class InternalError < RuntimeError
    end

    class Alarm
      def initialize(ts, &block)
        @timestamp = ts
        @block = block
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
      @timer_alarms = []
      @timer_action = timer_start_worker
    end

    # @private
    private action def timer_start_worker
      loop do
        begin
          interval = timer_next_timestamp&.-(Time.now)
          Thread.handle_interrupt(Reload => :on_blocking) do
            if interval.nil?
              Kernel.sleep
            elsif interval > 0.0
              Kernel.sleep(interval)
            end
          end
        rescue Reload
        else
          timer_fire
        end
      end
    end

    # Schedule a one shot alarm
    #
    # Call the given block after half a second:
    #   timer_after(0.5) do
    #     # executed in 0.5 seconds
    #   end
    sync_call def timer_after(seconds, now=Time.now, &block)
      a = OneTimeAlarm.new(now + seconds, &block)
      timer_add_alarm(a)
      a
    end

    # Schedule a repeated alarm
    #
    # Call the given block in after half a second and then repeatedly every 0.5 seconds:
    #   timer_after(0.5) do
    #     # executed every 0.5 seconds
    #   end
    sync_call def timer_every(seconds, now=Time.now, &block)
      a = RepeatedAlarm.new(now + seconds, seconds, &block)
      timer_add_alarm(a)
      a
    end

    # Cancel an alarm previously scheduled per timer_after or timer_every
    async_call def timer_cancel(alarm)
      a = @timer_alarms.delete(alarm)
      if a
        timer_check_integrity
      end
    end

    # @private
    private def timer_add_alarm(alarm)
      i = @timer_alarms.bsearch_index {|t| t.timestamp <= alarm.timestamp }
      if i
        @timer_alarms[i, 0] = alarm
      else
        @timer_alarms << alarm
        @timer_action.raise(Reload) unless @timer_action.current?
      end
      timer_check_integrity
    end

    private def timer_check_integrity
      @timer_alarms.inject(nil) do |min, a|
        raise InternalError, "alarms are not ordered: #{@timer_alarms.inspect}" if min && min < a.timestamp
        a.timestamp
      end
    end

    # @private
    private sync_call def timer_next_timestamp
      @timer_alarms.last&.timestamp
    end

    # @private
    private sync_call def timer_fire(now=Time.now)
      while @timer_alarms.last&.timestamp&.<=(now)
        a = @timer_alarms.pop
        if a.fire_then_repeat?(now)
          timer_add_alarm(a)
        end
        timer_check_integrity
      end
      # the method result is irrelevant, but sync_call is necessary to yield the timer blocks
      nil
    end
  end
end
