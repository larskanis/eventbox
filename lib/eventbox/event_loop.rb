class Eventbox
  # @private
  #
  # This class manages the calls to internal methods and procs comparable to an event loop.
  # It doesn't use an explicit event loop, but uses the calling thread to process the event.
  #
  # All methods prefixed with "_" requires @mutex acquired to be called.
  class EventLoop
    def initialize(threadpool, guard_time)
      @threadpool = threadpool
      @action_threads = []
      @action_threads_for_gc = []
      @mutex = Mutex.new
      @shutdown = false
      @guard_time_proc = case guard_time
        when NilClass
          nil
        when Numeric
          guard_time and proc do |dt, name|
            if dt > guard_time
              ecaller = caller.find{|t| !(t=~/lib\/eventbox(\/|\.rb:)/) }
              warn "guard time exceeded: #{"%2.3f" % dt} sec (limit is #{guard_time}) in `#{name}' called from `#{ecaller}' - please move blocking tasks to actions"
            end
          end
        when Proc
          guard_time
        else
          raise ArgumentError, "guard_time should be Numeric, Proc or nil"
      end
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
    def internal_thread?
      @mutex.owned?
    end

    def with_call_frame(name, answer_queue)
      @mutex.lock
      begin
        @latest_answer_queue = answer_queue
        @latest_call_name = name
        start_time = Time.now
        yield
      ensure
        diff_time = Time.now - start_time
        @latest_answer_queue = nil
        @latest_call_name = nil
        @mutex.unlock
        @guard_time_proc&.call(diff_time, name)
      end
    end

    def async_call(box, name, args, block)
      with_call_frame(name, nil) do
        box.send("__#{name}__", *args, &block)
      end
    end

    def sync_call(box, name, args, answer_queue, block)
      with_call_frame(name, answer_queue) do
        res = box.send("__#{name}__", *args, &block)
        res = ArgumentSanitizer.sanitize_values(res, self, :extern)
        answer_queue << res
      end
    end

    def yield_call(box, name, args, answer_queue, block)
      with_call_frame(name, answer_queue) do
        box.send("__#{name}__", *args, _result_proc(answer_queue, name), &block)
      end
    end

    # Anonymous version of async_call
    def async_proc_call(pr, args)
      with_call_frame(AsyncProc, nil) do
        pr.yield(*args)
      end
    end

    # Anonymous version of sync_call
    def sync_proc_call(pr, args, answer_queue)
      with_call_frame(SyncProc, answer_queue) do
        res = pr.yield(*args)
        res = ArgumentSanitizer.sanitize_values(res, self, :extern)
        answer_queue << res
      end
    end

    # Anonymous version of yield_call
    def yield_proc_call(pr, args, answer_queue)
      with_call_frame(YieldProc, answer_queue) do
        pr.yield(*args, _result_proc(answer_queue, pr))
      end
    end

    # Called when an external proc finished
    def external_proc_result(cbresult, res)
      with_call_frame(ExternalProc, nil) do
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
          args = ArgumentSanitizer.sanitize_values(args, self, self)
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
          args = ArgumentSanitizer.sanitize_values(args, self, self)
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
          args = ArgumentSanitizer.sanitize_values(args, self, self)
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
        resu = ArgumentSanitizer.return_args(resu)
        resu = ArgumentSanitizer.sanitize_values(resu, self, :extern)
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
            # called internally
            _external_proc_call(arg, name, args, block)
          else
            # called externally
            raise InvalidAccess, "external proc #{arg.inspect} #{"wrapped by #{name} " if name} should be unwrapped externally"
          end
        end
      end
    end

    def callback_loop(answer_queue)
      loop do
        rets = answer_queue.deq
        case rets
        when EventLoop::Callback
          args = rets.args
          cbres = rets.block.yield(*args)

          if rets.cbresult
            cbres = ArgumentSanitizer.sanitize_values(cbres, self, self)
            external_proc_result(rets.cbresult, cbres)
          end
        else
          answer_queue.close if answer_queue.respond_to?(:close)
          return rets
        end
      end
    end

    # Mark an object as to be shared instead of copied.
    def shared_object(object)
      if internal_thread?
        ObjectRegistry.set_tag(object, self)
      else
        ObjectRegistry.set_tag(object, ExternalSharedObject)
      end
      object
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
        @latest_answer_queue << Callback.new(block, ArgumentSanitizer.sanitize_values(cbargs, self, :extern), cbresult)
      elsif @latest_call_name
        raise(InvalidAccess, "closure #{"defined by `#{name}' " if name}was yielded by `#{@latest_call_name}', which must a sync_call, yield_call or internal proc")
      else
        raise(InvalidAccess, "closure #{"defined by `#{name}' " if name}was yielded by some event but should have been by a sync_call or yield_call")
      end
    end

    def _start_action(meth, name, args)
      qu = Queue.new

      new_thread = Thread.handle_interrupt(Exception => :never) do
        @threadpool.new do
          begin
            Thread.handle_interrupt(AbortAction => :on_blocking) do
              if meth.arity == args.length
                meth.call(*args)
              else
                meth.call(*args, qu.deq)
              end
            end
          rescue AbortAction
            # Do nothing, just exit the action
          rescue WeakRef::RefError
            # It can happen that the GC already swept the Eventbox instance, before some instance action is in a blocking state.
            # In this case access to the Eventbox instance raises a RefError.
            # Since it's now impossible to execute the action up to a blocking state, abort the action prematurely.
            raise unless @shutdown
          ensure
            thread_finished(qu.deq)
          end
        end
      end

      a = Action.new(name, new_thread, self)
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
