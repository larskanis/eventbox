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
        box.send("__#{name}__", *sanity_after_queue(args), &_cb_handler(sanity_after_queue(block)))
      end
    end

    def sync_call(box, name, args, answer_queue, block)
      with_call_frame(name, answer_queue) do
        res = box.send("__#{name}__", *sanity_after_queue(args), &_cb_handler(sanity_after_queue(block)))
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
        end, &_cb_handler(sanity_after_queue(block)))
      end
    end

    # Anonymous version of yield_call
    def internal_proc_call(pr, args, answer_queue)
      with_call_frame(InternalProc, answer_queue) do
        result = nil
        pr.yield(*sanity_after_queue(args), proc do |*resu|
          raise MultipleResults, "received multiple results for method `#{name}'" if result
          result = resu
          resu = return_args(resu)
          resu = sanity_before_queue(resu)
          answer_queue << resu
        end)
      end
    end

    # Anonymous version of async_call
    def external_proc_result(cbresult, res)
      with_call_frame(ExternalProc, nil) do
        res = sanity_after_queue(res)
        cbresult.yield(*res)
      end
    end

    def thread_finished(thread)
      @mutex.synchronize do
        @action_threads.delete(thread) or raise(ArgumentError, "unknown thread has finished")
      end
    end

    Callback = Struct.new :block, :args, :cbresult

    def _external_proc_call(block, name, cbargs, cbresult)
      if @latest_answer_queue
        @latest_answer_queue << Callback.new(sanity_before_queue(block), sanity_before_queue(cbargs), cbresult)
      elsif @latest_call_name
        raise(InvalidAccess, "closure #{"defined by `#{name}' " if name}was yielded by `#{@latest_call_name}', which must a sync_call, yield_call or internal proc")
      else
        raise(InvalidAccess, "closure #{"defined by `#{name}' " if name}was yielded by some event but should have been by a sync_call or yield_call")
      end
    end

    private def _cb_handler(block)
      proc do |*cbargs, &cbresult|
        block.yield(*cbargs, &cbresult)
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
