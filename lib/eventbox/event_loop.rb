class Eventbox
  # @private
  #
  # This class manages the calls to event scope methods and procs comparable to an event loop.
  # It doesn't use an explicit event loop, but uses the calling thread to process the event.
  #
  # All methods prefixed with "_" requires @mutex acquired to be called.
  class EventLoop
    def initialize(threadpool, guard_time)
      @threadpool = threadpool
      @running_actions = []
      @running_actions_for_gc = []
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
    def send_shutdown(object_id=nil)
#       warn "shutdown called for object #{object_id} with #{@running_actions.size} threads #{@running_actions.map(&:object_id).join(",")}"

      # The finalizer doesn't allow suspension per Mutex, so that we access a read-only copy of @running_actions.
      # To avoid race conditions with thread creation, set a flag before the loop.
      @shutdown = true

      # terminate all running action threads
      begin
        @running_actions_for_gc.each(&:abort)
      rescue ThreadError
        # ThreadPool requires to lock a mutex, which fails in trap context.
        # So defer the abort through another thread.
        Thread.new do
          @running_actions_for_gc.each(&:abort)
        end
      end

      nil
    end

    def shutdown(&completion_block)
      send_shutdown
      if event_scope?
        if completion_block
          completion_block = new_async_proc(&completion_block)

          # Thread might not be tagged to a calling event scope
          source_event_loop = Thread.current.thread_variable_get(:__event_loop__)
          Thread.current.thread_variable_set(:__event_loop__, nil)
          begin
            @threadpool.new do
              @running_actions_for_gc.each(&:join)
              completion_block.call
            end
          ensure
            Thread.current.thread_variable_set(:__event_loop__, source_event_loop)
          end
        end
      else
        raise InvalidAccess, "external shutdown call doesn't take a block but blocks until threads have terminated" if completion_block
        @running_actions_for_gc.each(&:join)
      end
    end

    # Make a copy of the thread list for use in shutdown.
    # The copy is replaced per an atomic operation, so that it can be read lock-free in shutdown.
    def _update_action_threads_for_gc
      @running_actions_for_gc = @running_actions.dup
    end

    # Is the caller running within the event scope context?
    def event_scope?
      @mutex.owned?
    end

    def synchronize_external
      if event_scope?
        yield
      else
        @mutex.synchronize do
          yield
        end
      end
    end

    def with_call_frame(name, answer_queue)
      source_event_loop = Thread.current.thread_variable_get(:__event_loop__) || :extern
      @mutex.lock
      begin
        Thread.current.thread_variable_set(:__event_loop__, self)
        @latest_answer_queue = answer_queue
        @latest_call_name = name
        start_time = Time.now
        yield(source_event_loop)
      ensure
        @latest_answer_queue = nil
        @latest_call_name = nil
        @mutex.unlock
        diff_time = Time.now - start_time
        @guard_time_proc&.call(diff_time, name)
        Thread.current.thread_variable_set(:__event_loop__, source_event_loop)
      end
      source_event_loop
    end

    def async_call(box, name, args, block)
      sel = with_call_frame(name, nil) do |source_event_loop|
        args = Sanitizer.sanitize_values(args, source_event_loop, self, name)
        block = Sanitizer.sanitize_value(block, source_event_loop, self, name)
        box.send("__#{name}__", *args, &block)
      end
    end

    def sync_call(box, name, args, block)
      answer_queue = Queue.new
      sel = with_call_frame(name, answer_queue) do |source_event_loop|
        args = Sanitizer.sanitize_values(args, source_event_loop, self, name)
        block = Sanitizer.sanitize_value(block, source_event_loop, self, name)
        res = box.send("__#{name}__", *args, &block)
        res = Sanitizer.sanitize_value(res, self, source_event_loop)
        answer_queue << res
      end
      callback_loop(answer_queue, sel)
    end

    def yield_call(box, name, args, block)
      answer_queue = Queue.new
      sel = with_call_frame(name, answer_queue) do |source_event_loop|
        args = Sanitizer.sanitize_values(args, source_event_loop, self, name)
        block = Sanitizer.sanitize_value(block, source_event_loop, self, name)
        box.send("__#{name}__", *args, _completion_proc(answer_queue, name, source_event_loop), &block)
      end
      callback_loop(answer_queue, sel)
    end

    # Anonymous version of async_call
    def async_proc_call(pr, args, arg_block)
      with_call_frame(AsyncProc, nil) do |source_event_loop|
        args = Sanitizer.sanitize_values(args, source_event_loop, self)
        arg_block = Sanitizer.sanitize_value(arg_block, source_event_loop, self)
        pr.yield(*args, &arg_block)
      end
    end

    # Anonymous version of sync_call
    def sync_proc_call(pr, args, arg_block)
      answer_queue = Queue.new
      sel = with_call_frame(SyncProc, answer_queue) do |source_event_loop|
        args = Sanitizer.sanitize_values(args, source_event_loop, self)
        arg_block = Sanitizer.sanitize_value(arg_block, source_event_loop, self)
        res = pr.yield(*args, &arg_block)
        res = Sanitizer.sanitize_value(res, self, source_event_loop)
        answer_queue << res
      end
      callback_loop(answer_queue, sel)
    end

    # Anonymous version of yield_call
    def yield_proc_call(pr, args, arg_block)
      answer_queue = Queue.new
      sel = with_call_frame(YieldProc, answer_queue) do |source_event_loop|
        args = Sanitizer.sanitize_values(args, source_event_loop, self)
        arg_block = Sanitizer.sanitize_value(arg_block, source_event_loop, self)
        pr.yield(*args, _completion_proc(answer_queue, pr, source_event_loop), &arg_block)
      end
      callback_loop(answer_queue, sel)
    end

    # Called when an external proc finished
    def external_proc_result(cbresult, res)
      with_call_frame(ExternalProc, nil) do
        cbresult.yield(*res)
      end
    end

    def new_async_proc(name=nil, klass=AsyncProc, &block)
      pr = klass.new do |*args, &arg_block|
        if event_scope?
          # called in the event scope
          block.yield(*args, &arg_block)
        else
          # called externally
          async_proc_call(block, args, arg_block)
        end
        pr
      end
    end

    def new_sync_proc(name=nil, &block)
      SyncProc.new do |*args, &arg_block|
        if event_scope?
          # called in the event scope
          block.yield(*args, &arg_block)
        else
          # called externally
          sync_proc_call(block, args, arg_block)
        end
      end
    end

    def new_yield_proc(name=nil, &block)
      YieldProc.new do |*args, &arg_block|
        if event_scope?
          # called in the event scope
          safe_yield_result(args, block)
          block.yield(*args, &arg_block)
          nil
        else
          # called externally
          yield_proc_call(block, args, arg_block)
        end
      end
    end

    def safe_yield_result(args, name)
      complete = args.last
      unless Proc === complete
        if Proc === name
          raise InvalidAccess, "yield_proc #{name.inspect} must be called with a Proc object in the event scope but got #{complete.class}"
        else
          raise InvalidAccess, "yield_call `#{name}' must be called with a Proc object in the event scope but got #{complete.class}"
        end
      end
      args[-1] = proc do |*cargs, &cblock|
        unless complete
          if Proc === name
            raise MultipleResults, "received multiple results for #{name.inspect}"
          else
            raise MultipleResults, "received multiple results for method `#{name}'"
          end
        end
        res = complete.yield(*cargs, &cblock)
        complete = nil
        res
      end
    end

    private def _completion_proc(answer_queue, name, source_event_loop)
      new_async_proc(name, CompletionProc) do |*resu|
        unless answer_queue
          if Proc === name
            raise MultipleResults, "received multiple results for #{name.inspect}"
          else
            raise MultipleResults, "received multiple results for method `#{name}'"
          end
        end
        resu = Sanitizer.sanitize_values(resu, self, source_event_loop)
        resu = Sanitizer.return_args(resu)
        answer_queue << resu
        answer_queue = nil
      end
    end

    def callback_loop(answer_queue, source_event_loop)
      loop do
        rets = answer_queue.deq
        case rets
        when Callback
          cbres = rets.block.yield(*rets.args, &rets.arg_block)

          if rets.cbresult
            cbres = Sanitizer.sanitize_value(cbres, self, source_event_loop)
            external_proc_result(rets.cbresult, cbres)
          end
        when WrappedException
          answer_queue.close if answer_queue.respond_to?(:close)
          raise(*rets.exc)
        else
          answer_queue.close if answer_queue.respond_to?(:close)
          return rets
        end
      end
    end

    # Mark an object as to be shared instead of copied.
    def shared_object(object)
      if event_scope?
        ObjectRegistry.set_tag(object, self)
      else
        ObjectRegistry.set_tag(object, ExternalSharedObject)
      end
      object
    end

    def thread_finished(action)
      @mutex.synchronize do
        @running_actions.delete(action) or raise(ArgumentError, "unknown action has finished: #{action}")
        _update_action_threads_for_gc
      end
    end

    Callback = Struct.new :block, :args, :arg_block, :cbresult

    def _external_proc_call(block, name, args, arg_block, cbresult, source_event_loop)
      if @latest_answer_queue
        args = Sanitizer.sanitize_values(args, self, source_event_loop)
        arg_block = Sanitizer.sanitize_value(arg_block, self, source_event_loop)
        @latest_answer_queue << Callback.new(block, args, arg_block, cbresult)
        nil
      else
        raise(InvalidAccess, "closure #{"defined by `#{name}' " if name}was yielded by `#{@latest_call_name}', which must a sync_call, yield_call or event scope proc")
      end
    end

    def start_action(meth, name, args)
      # Actions might not be tagged to a calling event scope
      source_event_loop = Thread.current.thread_variable_get(:__event_loop__)
      Thread.current.thread_variable_set(:__event_loop__, nil)

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

      # Add to the list of running actions
      synchronize_external do
        @running_actions << a
        _update_action_threads_for_gc
      end

      # Enqueue the action twice (for call and for finish)
      qu << a << a

      # @shutdown is set without a lock, so that we need to re-check, if it was set while start_action
      if @shutdown
        a.abort
        a.join
      end

      a
    ensure
      Thread.current.thread_variable_set(:__event_loop__, source_event_loop)
    end
  end
end
