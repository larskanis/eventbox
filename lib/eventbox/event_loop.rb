class Eventbox
  class EventLoop
    include ArgumentSanitizer

    def initialize(threadpool)
      @threadpool = threadpool
      @action_threads = {}
      @ctrl_thread = nil
      @mutex = Mutex.new
      @shutdown = false
    end

    def event_loop
      self
    end

    def shutdown
      @mutex.synchronize do
        _shutdown
      end
      nil
    end

    def _abort_thread(thread, reason)
      thread.raise AbortAction, "abort action thread by #{reason}"
    end

    def _shutdown(object_id=nil)
#       warn "shutdown called for object #{object_id} with #{@action_threads.size} threads #{@action_threads.map(&:first).map(&:object_id).join(",")}"

      # The finalizer doesn't allow suspension per Mutex, so that we access @action_threads unprotected.
      # To avoid race conditions with thread creation, set a flag before the loop.
      @shutdown = true

      # terminate all running action threads
      @action_threads.each do |th, _|
        _abort_thread(th, "garbage collector".freeze)
      end
    end

    def internal_thread?
      Thread.current==@ctrl_thread
    end

    def with_call_frame(name, answer_queue)
      @mutex.synchronize do
        @latest_answer_queue = answer_queue
        @latest_call_name = name
        @ctrl_thread = Thread.current
        begin
          yield
        ensure
          @latest_answer_queue = nil
          @latest_call_name = nil
          @ctrl_thread = nil
        end
      end
    end

    def async_call(box, name, args, block)
      with_call_frame(name, nil) do
        box.send("__#{name}__", *sanity_after_queue(args), &sanity_after_queue(block))
      end
    end

    def sync_call(box, name, args, answer_queue, block)
      with_call_frame(name, answer_queue) do
        res = box.send("__#{name}__", *sanity_after_queue(args), &sanity_after_queue(block))
        res = sanity_before_queue(res)
        answer_queue << res
      end
    end

    def yield_call(box, name, args, answer_queue, block)
      with_call_frame(name, answer_queue) do
        box.send("__#{name}__", *sanity_after_queue(args), _result_proc(answer_queue, name), &sanity_after_queue(block))
      end
    end

    # Anonymous version of async_call
    def async_proc_call(pr, args)
      with_call_frame(AsyncProc, nil) do
        pr.yield(*sanity_after_queue(args))
      end
    end

    # Anonymous version of sync_call
    def sync_proc_call(pr, args, answer_queue)
      with_call_frame(SyncProc, answer_queue) do
        res = pr.yield(*sanity_after_queue(args))
        res = sanity_before_queue(res)
        answer_queue << res
      end
    end

    # Anonymous version of yield_call
    def yield_proc_call(pr, args, answer_queue)
      with_call_frame(YieldProc, answer_queue) do
        pr.yield(*sanity_after_queue(args), _result_proc(answer_queue, pr))
      end
    end

    # Anonymous version of async_call
    def external_proc_result(cbresult, res)
      with_call_frame(ExternalProc, nil) do
        res = sanity_after_queue(res)
        cbresult.yield(*res)
      end
    end

    def new_async_proc(name=nil, &block)
      AsyncProc.new(block, self, name) do |*args, &cbblock|
        raise InvalidAccess, "yieding a #{self.class} with block is not supported" if cbblock
        if internal_thread?
          # called internally
          block.yield(*args)
        else
          # called externally
          args = sanity_before_queue(args)
          async_proc_call(block, args)
        end
      end
    end

    def new_sync_proc(name=nil, &block)
      SyncProc.new(block, self, name) do |*args, &cbblock|
        raise InvalidAccess, "yieding a #{self.class} with block is not supported" if cbblock
        if internal_thread?
          # called internally
          block.yield(*args)
        else
          # called externally
          answer_queue = Queue.new
          args = sanity_before_queue(args)
          sync_proc_call(block, args, answer_queue)
          callback_loop(answer_queue)
        end
      end
    end

    def new_yield_proc(name=nil, &block)
      YieldProc.new(block, self, name) do |*args, &cbblock|
        raise InvalidAccess, "yieding a #{self.class} with block is not supported" if cbblock
        if internal_thread?
          # called internally
          raise InvalidAccess, "internal yield_proc #{block.inspect} #{"wrapped by #{name} " if name} can not be called internally - use sync_proc or async_proc instead"
        else
          # called externally
          answer_queue = Queue.new
          args = sanity_before_queue(args)
          yield_proc_call(block, args, answer_queue)
          callback_loop(answer_queue)
        end
      end
    end

    private def _result_proc(answer_queue, name)
      result_yielded = false
      new_async_proc(name) do |*resu|
        if result_yielded
          if Proc === name
            raise MultipleResults, "received multiple results for #{pr.inspect}"
          else
            raise MultipleResults, "received multiple results for method `#{name}'"
          end
        end
        resu = return_args(resu)
        resu = sanity_before_queue(resu)
        answer_queue << resu
        result_yielded = true
      end
    end

    def wrap_proc(arg, name)
      if internal_thread?
        InternalObject.new(arg, self, name)
      else
        ExternalProc.new(arg, self, name) do |*args, &block|
          if !internal_thread?
            # called externally
            raise InvalidAccess, "external proc #{arg.inspect} #{"wrapped by #{name} " if name} should be unwrapped externally"
          else
            # called internally
            _external_proc_call(arg, name, args, block)
          end
        end
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
        @latest_answer_queue << Callback.new(block, sanity_before_queue(cbargs), cbresult)
      elsif @latest_call_name
        raise(InvalidAccess, "closure #{"defined by `#{name}' " if name}was yielded by `#{@latest_call_name}', which must a sync_call, yield_call or internal proc")
      else
        raise(InvalidAccess, "closure #{"defined by `#{name}' " if name}was yielded by some event but should have been by a sync_call or yield_call")
      end
    end

    def _start_action(meth, args)
      new_thread = Thread.handle_interrupt(AbortAction => :never) do
        @threadpool.new do
          begin
            Thread.handle_interrupt(AbortAction => :on_blocking) do
              args = sanity_after_queue(args)

              meth.call(*args)
            end
          rescue AbortAction
          ensure
            thread_finished(Thread.current)
          end
        end
      end
      @action_threads[new_thread] = true

      _abort_thread(new_thread, "pending shutdown".freeze) if @shutdown
    end
  end
end
