class Eventbox
  class EventLoop
    include ArgumentSanitizer

    def initialize(threadpool)
      @threadpool = threadpool
      @action_threads = {}
      @ctrl_thread = nil
      @mutex = Mutex.new
    end

    def event_loop
      self
    end

    def shutdown(object_id=nil)
#       warn "shutdown called for object #{object_id}"

      @mutex.synchronize do
        # terminate all running action threads
        @action_threads.each do |th, _|
          th.exit
        end

        # TODO Closing the queue leads to ClosedQueueError on JRuby due to enqueuing of ThreadFinished objects.
        # @input_queue.close
      end

      nil
    end

    def internal_thread?
      Thread.current==@ctrl_thread
    end

    def with_call_frame(name, answer_queue)
      @mutex.synchronize do
        @latest_answer_queue = answer_queue
        @latest_call_name = name
        @ctrl_thread = Thread.current
        yield
        @latest_answer_queue = nil
        @latest_call_name = nil
        @ctrl_thread = nil
      end
    end

    def async_call(box, name, args, block)
      with_call_frame(name, nil) do
        box.send("__#{name}__", *sanity_after_queue(args), &_cb_handler(box, name, block))
      end
    end

    def sync_call(box, name, args, answer_queue, block)
      with_call_frame(name, answer_queue) do
        res = box.send("__#{name}__", *sanity_after_queue(args), &_cb_handler(box, name, block))
        res = sanity_before_queue(res)
        answer_queue << res
      end
    end

    def yield_call(box, name, args, answer_queue, block)
      with_call_frame(name, answer_queue) do
        result = nil
        box.send("__#{name}__", *sanity_after_queue(args), proc do |*resu|
          raise MultipleResults, "received multiple results for method `#{name}'" if result
          result = resu
          resu = return_args(resu)
          resu = sanity_before_queue(resu)
          answer_queue << resu
        end, &_cb_handler(box, name, block))
      end
    end

    def callback_result(box, res, cbresult)
      with_call_frame(nil, nil) do
        cbres = sanity_after_queue(res)
        cbresult.yield(cbres)
      end
    end

    def thread_finished(thread)
      @mutex.synchronize do
        @action_threads.delete(thread) or raise(ArgumentError, "unknown thread has finished")
      end
    end

    private def _cb_handler(box, name, block)
      proc do |*cbargs, &cbresult|
        cbargs = sanity_after_queue(cbargs)
        if @latest_answer_queue
          @latest_answer_queue << Callback.new(box, cbargs, cbresult, block)
        elsif @latest_call_name
          raise(InvalidAccess, "closure defined by `#{name}' was yielded by `#{@latest_call_name}', which must a sync_call or yield_call")
        else
          raise(InvalidAccess, "closure defined by `#{name}' was yielded by some event but should have been by a sync_call or yield_call")
        end
      end
    end

    def _start_action(meth, args)
      new_thread = @threadpool.new do
        args = sanity_after_queue(args)

        meth.call(*args)
        thread_finished(Thread.current)
      end

      @action_threads[new_thread] = true
    end
  end
end
