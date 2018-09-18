class Eventbox
  class EventLoop
    include ArgumentSanitizer

    def initialize(input_queue, loop_running, threadpool)
      @input_queue = input_queue
      @loop_running = loop_running
      @threadpool = threadpool

      threadpool.new(&method(:start))
    end

    def start
      @ctrl_thread = Thread.current
      @action_threads = {}

      @loop_running << @ctrl_thread

      run_event_loop

      # terminate all running action threads
      @action_threads.each do |th, _|
        th.exit
      end

      # TODO Closing the queue leads to ClosedQueueError on JRuby due to enqueuing of ThreadFinished objects.
      # @input_queue.close
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
        call = @input_queue.deq
        latest_call = call
        case call
        when SyncCall
          res = call.box.send("__#{call.name}__", *sanity_after_queue(call.args))
          res = sanity_before_queue(res)
          call.answer_queue << res
        when YieldCall
          result = nil
          call.box.send("__#{call.name}__", *sanity_after_queue(call.args), proc do |*resu|
            raise MultipleResults, "received multiple results for method `#{call.name}'" if result
            result = resu
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
        when AsyncCall
          call.box.send("__#{call.name}__", *sanity_after_queue(call.args))
        when CallbackResult
          cbres = sanity_after_queue(call.res)
          call.cbresult.yield(cbres)
        when ThreadFinished
          @action_threads.delete(call.thread) or raise(ArgumentError, "unknown thread has finished")
        when :shutdown
          break
        else
          raise ArgumentError, "invalid call type #{call.inspect}"
        end
      end
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
