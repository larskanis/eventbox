class Eventbox
  class EventLoop
    include ArgumentSanitizer

    def initialize(input_queue, loop_running, threadpool)
      @input_queue = input_queue
      @loop_running = loop_running
      @threadpool = threadpool
      @exit_event_loop = false

      threadpool.new(&method(:start))
    end

    def start
      @ctrl_thread = Thread.current
      @action_threads = {}

      @loop_running << @ctrl_thread
      run_event_loop
    end

    def shutdown(object_id=nil)
#       warn "shutdown called for object #{object_id}"
      @input_queue << :shutdown
      nil
    end

    # Run the event loop.
    #
    # The event loop processes the input queue by executing the enqueued method calls.
    # It can be stopped by #shutdown .
    def run_event_loop
      latest_call = nil
      loop do
        after_events_box = nil
        loop do
          call = @input_queue.deq
          latest_call = call
          box = case call
          when SyncCall
            res = call.box.send("__#{call.name}__", *sanity_after_queue(call.args))
            res = sanity_before_queue(res)
            call.answer_queue << res
            call.box
          when YieldCall
            call.box.send("__#{call.name}__", *sanity_after_queue(call.args), proc do |*resu|
              resu = return_args(resu)
              resu = sanity_before_queue(resu)
              call.answer_queue << resu
            end) do |*cbargs, &cbresult|
              cbargs = sanity_after_queue(cbargs)
              case latest_call
              when YieldCall, SyncCall
                latest_call.answer_queue << Callback.new(call.box, cbargs, cbresult, call.block)
              else
                raise(InvalidAccess, "closure defined by `#{call.name}' was yielded by `#{latest_call.name}', which must a sync_call or yield_call")
              end
            end
            call.box
          when AsyncCall
            call.box.send("__#{call.name}__", *sanity_after_queue(call.args))
            call.box
          when CallbackResult
            cbres = sanity_after_queue(call.res)
            call.cbresult.yield(cbres)
            call.box
          when ThreadFinished
            @action_threads.delete(call.thread) or raise(ArgumentError, "unknown thread has finished")
            nil
          when :shutdown
            @exit_event_loop = true
            nil
          else
            raise ArgumentError, "invalid call type #{call.inspect}"
          end

          if box
            box.send(:after_each_event)
            after_events_box = box
          end
          break if @input_queue.empty?
        end
        break if @exit_event_loop

        after_events_box.send(:after_events) if after_events_box
      end

      # terminate all running action threads
      @action_threads.each do |th, _|
        th.exit
      end

      # TODO Closing the queue leads to ClosedQueueError on JRuby due to enqueuing of ThreadFinished objects.
      # @input_queue.close
    end

    def start_action(meth, args)
      new_thread = @threadpool.new do
        args = sanity_after_queue(args)

        meth.call(*args)
        @input_queue << ThreadFinished.new(Thread.current)
      end

      @action_threads[new_thread] = true
    end
  end
end
