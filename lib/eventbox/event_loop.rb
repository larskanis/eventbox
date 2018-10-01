class Eventbox
  # @private
  #
  # This class manages the calls to internal methods and procs comparable to an event loop.
  # It doesn't use an explicit event loop, but uses the calling thread to process the event.
  #
  # All methods prefixed with "_" requires @mutex acquired to be called.
  class EventLoop
    include ArgumentSanitizer

    def initialize(threadpool, guard_time)
      @threadpool = threadpool
      @action_threads = []
      @action_threads_for_gc = []
      @ctrl_thread = nil
      @mutex = Mutex.new
      @shutdown = false
      @guard_time_proc = case guard_time
        when NilClass
          nil
        when Numeric
          guard_time and proc do |dt, name|
            if dt > guard_time
              warn "guard time exceeded: #{"%2.3f" % dt} sec (limit is #{guard_time}) in `#{name}' - please move blocking tasks to actions"
            end
          end
        when Proc
          guard_time
        else
          raise ArgumentError, "guard_time should be Numeric, Proc or nil"
      end
    end

    # Used in ArgumentSanitizer
    def event_loop
      self
    end

    # Abort all running action threads.
    def shutdown(object_id=nil)
#       warn "shutdown called for object #{object_id} with #{@action_threads.size} threads #{@action_threads.map(&:object_id).join(",")}"

      # The finalizer doesn't allow suspension per Mutex, so that we access a read-only copy of @action_threads.
      # To avoid race conditions with thread creation, set a flag before the loop.
      @shutdown = true

      # terminate all running action threads
      @action_threads_for_gc.each(&:abort)

      nil
    end

    # Make a copy of the thread list for use in shutdown.
    # The copy is replaced per an atomic operation, so that it can be read lock-free in shutdown.
    def _update_action_threads_for_gc
      @action_threads_for_gc = @action_threads.dup
    end

    # Is the caller running within the internal context?
    def internal_thread?(current_thread=Thread.current)
      # Access to @ctrl_thread is lock-free, because
      # - assignment to @ctrl_thread is atomic,
      # - equality comparison is atomic and
      # - @ctrl_thread is nil or a Thread and both evaluate to false for external threads.
      current_thread==@ctrl_thread
    end

    def with_call_frame(name, answer_queue)
      @mutex.lock
      begin
        @latest_answer_queue = answer_queue
        @latest_call_name = name
        @ctrl_thread = Thread.current
        start_time = Time.now
        yield
      ensure
        diff_time = Time.now - start_time
        @latest_answer_queue = nil
        @latest_call_name = nil
        @ctrl_thread = nil
        @mutex.unlock
        @guard_time_proc&.call(diff_time, name)
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
      AsyncProc.new do |*args, &cbblock|
        raise InvalidAccess, "calling #{block.inspect} with block argument is not supported" if cbblock
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
      SyncProc.new do |*args, &cbblock|
        raise InvalidAccess, "calling #{block.inspect} with block argument is not supported" if cbblock
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
      YieldProc.new do |*args, &cbblock|
        raise InvalidAccess, "calling #{block.inspect} with block argument is not supported" if cbblock
        if internal_thread?
          # called internally
          raise InvalidAccess, "yield_proc #{block.inspect} #{"wrapped by #{name} " if name} can not be called internally - use sync_proc or async_proc instead"
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
          if internal_thread?
            # called internally -> @mutex is already locked
            raise InvalidAccess, "external proc #{arg.inspect} #{"wrapped by #{name} " if name} should be called with acquired lock only" unless @mutex.locked?
            _external_proc_call(arg, name, args, block)
          else
            # called externally
            raise InvalidAccess, "external proc #{arg.inspect} #{"wrapped by #{name} " if name} should be unwrapped externally"
          end
        end
      end
    end

    def thread_finished(thread)
      @mutex.synchronize do
        @action_threads.delete(thread) or raise(ArgumentError, "unknown thread has finished")
        _update_action_threads_for_gc
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
      qu = Queue.new

      new_thread = Thread.handle_interrupt(Exception => :never) do
        @threadpool.new do
          begin
            Thread.handle_interrupt(AbortAction => :on_blocking) do
              args = sanity_after_queue(args)

              if meth.arity == args.length
                meth.call(*args)
              else
                meth.call(*args, qu.deq)
              end
            end
          rescue AbortAction
          ensure
            thread_finished(qu.deq)
          end
        end
      end

      a = Action.new(meth.name, new_thread, self)
      # Enqueue the action twice (for call and for finish)
      qu << a << a

      # Add to the list of running actions
      @action_threads << a
      _update_action_threads_for_gc

      # @shutdown is set without a lock, so that we need to re-check, if it was set while _start_action
      a.abort if @shutdown

      a
    end
  end
end
