# frozen-string-literal: true

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
      @shutdown = false
      @guard_time = guard_time
      _init_variables
    end

    def marshal_dump
      raise TypeError, "Eventbox objects can't be serialized within event scope" if event_scope?
      @mutex.synchronize do
        raise TypeError, "Eventbox objects can't be serialized while actions are running" unless @running_actions.empty?
        [@threadpool, @shutdown, @guard_time]
      end
    end

    def marshal_load(array)
      @threadpool, @shutdown, @guard_time = array
      _init_variables
    end

    def _init_variables
      @running_actions = []
      @running_actions_for_gc = []
      @mutex = Mutex.new
      @guard_time_proc = case @guard_time
        when NilClass
          nil
        when Numeric
          @guard_time and proc do |dt, name|
            if dt > @guard_time
              ecaller = caller.find{|t| !(t=~/lib\/eventbox(\/|\.rb:)/) }
              warn "guard time exceeded: #{"%2.3f" % dt} sec (limit is #{@guard_time}) in `#{name}' called from `#{ecaller}' - please move blocking tasks to actions"
            end
          end
        when Proc
          @guard_time
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
      source_event_loop = Thread.current.thread_variable_get(:__event_loop__)
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
        Thread.current.thread_variable_set(:__event_loop__, source_event_loop)
        diff_time = Time.now - start_time
        @guard_time_proc&.call(diff_time, name)
      end
      source_event_loop
    end

    def _latest_call_context
      if @latest_answer_queue
        ctx = BlockingExternalCallContext.new
        ctx.__answer_queue__ = @latest_answer_queue
      end
      ctx
    end

    def with_call_context(ctx)
      orig_context = @latest_answer_queue
      @latest_answer_queue = ctx.__answer_queue__
      yield
    ensure
      @latest_answer_queue = orig_context
    end

    def async_call(box, name, args, kwargs, block, wrapper)
      with_call_frame(name, nil) do |source_event_loop|
        args, kwargs = wrapper.call(source_event_loop, self, *args, **kwargs) if wrapper
        args = Sanitizer.sanitize_values(args, source_event_loop, self, name)
        kwargs = Sanitizer.sanitize_kwargs(kwargs, source_event_loop, self, name)
        block = Sanitizer.sanitize_value(block, source_event_loop, self, name)
        box.send("__#{name}__", *args, **kwargs, &block)
      end
    end

    def sync_call(box, name, args, kwargs, block, answer_queue, wrapper)
      with_call_frame(name, answer_queue) do |source_event_loop|
        args, kwargs = wrapper.call(source_event_loop, self, *args, **kwargs) if wrapper
        args = Sanitizer.sanitize_values(args, source_event_loop, self, name)
        kwargs = Sanitizer.sanitize_kwargs(kwargs, source_event_loop, self, name)
        block = Sanitizer.sanitize_value(block, source_event_loop, self, name)
        res = box.send("__#{name}__", *args, **kwargs, &block)
        res = Sanitizer.sanitize_value(res, self, source_event_loop)
        answer_queue << res
      end
    end

    def yield_call(box, name, args, kwargs, block, answer_queue, wrapper)
      with_call_frame(name, answer_queue) do |source_event_loop|
        args << new_completion_proc(answer_queue, name, source_event_loop)
        args, kwargs = wrapper.call(source_event_loop, self, *args, **kwargs) if wrapper
        args = Sanitizer.sanitize_values(args, source_event_loop, self, name)
        kwargs = Sanitizer.sanitize_kwargs(kwargs, source_event_loop, self, name)
        block = Sanitizer.sanitize_value(block, source_event_loop, self, name)
        box.send("__#{name}__", *args, **kwargs, &block)
      end
    end

    # Anonymous version of async_call
    def async_proc_call(pr, args, kwargs, arg_block, wrapper)
      with_call_frame(AsyncProc, nil) do |source_event_loop|
        args, kwargs = wrapper.call(source_event_loop, self, *args, **kwargs) if wrapper
        args = Sanitizer.sanitize_values(args, source_event_loop, self)
        kwargs = Sanitizer.sanitize_kwargs(kwargs, source_event_loop, self)
        arg_block = Sanitizer.sanitize_value(arg_block, source_event_loop, self)
        pr.yield(*args, **kwargs, &arg_block)
      end
    end

    # Anonymous version of sync_call
    def sync_proc_call(pr, args, kwargs, arg_block, answer_queue, wrapper)
      with_call_frame(SyncProc, answer_queue) do |source_event_loop|
        args, kwargs = wrapper.call(source_event_loop, self, *args, **kwargs) if wrapper
        args = Sanitizer.sanitize_values(args, source_event_loop, self)
        kwargs = Sanitizer.sanitize_kwargs(kwargs, source_event_loop, self)
        arg_block = Sanitizer.sanitize_value(arg_block, source_event_loop, self)
        res = pr.yield(*args, **kwargs, &arg_block)
        res = Sanitizer.sanitize_value(res, self, source_event_loop)
        answer_queue << res
      end
    end

    # Anonymous version of yield_call
    def yield_proc_call(pr, args, kwargs, arg_block, answer_queue, wrapper)
      with_call_frame(YieldProc, answer_queue) do |source_event_loop|
        args << new_completion_proc(answer_queue, pr, source_event_loop)
        args, kwargs = wrapper.call(source_event_loop, self, *args, **kwargs) if wrapper
        args = Sanitizer.sanitize_values(args, source_event_loop, self)
        kwargs = Sanitizer.sanitize_kwargs(kwargs, source_event_loop, self)
        arg_block = Sanitizer.sanitize_value(arg_block, source_event_loop, self)
        pr.yield(*args, **kwargs, &arg_block)
      end
    end

    # Called when an external object call finished
    def external_call_result(cbresult, res, answer_queue, wrapper)
      with_call_frame(ExternalObject, answer_queue) do |source_event_loop|
        res, _ = wrapper.call(source_event_loop, self, res) if wrapper
        res = Sanitizer.sanitize_value(res, source_event_loop, self)
        cbresult.yield(*res)
      end
    end

    def new_async_proc(name=nil, klass=AsyncProc, &block)
      raise InvalidAccess, "async_proc outside of the event scope is not allowed" unless event_scope?
      wrapper = ArgumentWrapper.build(block, "async_proc #{name}")
      pr = klass.new do |*args, **kwargs, &arg_block|
        if event_scope?
          # called in the event scope
          block.yield(*args, **kwargs, &arg_block)
        else
          # called externally
          async_proc_call(block, args, kwargs, arg_block, wrapper)
        end
        pr
      end
    end

    def new_sync_proc(name=nil, &block)
      raise InvalidAccess, "sync_proc outside of the event scope is not allowed" unless event_scope?
      wrapper = ArgumentWrapper.build(block, "sync_proc #{name}")
      SyncProc.new do |*args, **kwargs, &arg_block|
        if event_scope?
          # called in the event scope
          block.yield(*args, **kwargs, &arg_block)
        else
          # called externally
          answer_queue = Queue.new
          sel = sync_proc_call(block, args, kwargs, arg_block, answer_queue, wrapper)
          callback_loop(answer_queue, sel, block)
        end
      end
    end

    def new_yield_proc(name=nil, &block)
      raise InvalidAccess, "yield_proc outside of the event scope is not allowed" unless event_scope?
      wrapper = ArgumentWrapper.build(block, "yield_proc #{name}")
      YieldProc.new do |*args, **kwargs, &arg_block|
        if event_scope?
          # called in the event scope
          internal_yield_result(args, block)
          block.yield(*args, **kwargs, &arg_block)
          nil
        else
          # called externally
          answer_queue = Queue.new
          sel = yield_proc_call(block, args, kwargs, arg_block, answer_queue, wrapper)
          callback_loop(answer_queue, sel, block)
        end
      end
    end

    def internal_yield_result(args, name)
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
            raise MultipleResults, "second result yielded for #{name.inspect} that already returned"
          else
            raise MultipleResults, "second result yielded for method `#{name}' that already returned"
          end
        end
        res = complete.yield(*cargs, &cblock)
        complete = nil
        res
      end
    end

    private def new_completion_proc(answer_queue, name, source_event_loop)
      pr = new_async_proc(name, CompletionProc) do |*resu|
        unless answer_queue
          # It could happen, that two threads call the CompletionProc simultanously so that nothing is raised here.
          # In this case the failure is caught in callback_loop instead, but in all other cases the failure is raised early here at the caller side.
          if Proc === name
            raise MultipleResults, "second result yielded for #{name.inspect} that already returned"
          else
            raise MultipleResults, "second result yielded for method `#{name}' that already returned"
          end
        end
        resu = Sanitizer.sanitize_values(resu, self, source_event_loop)
        resu = Sanitizer.return_args(resu)
        answer_queue << resu
        answer_queue = nil
      end
      pr.__answer_queue__ = answer_queue
      pr
    end

    def callback_loop(answer_queue, source_event_loop, name)
      loop do
        rets = answer_queue.deq
        case rets
        when ExternalObjectCall
          cbres = rets.object.send(rets.method, *rets.args, **rets.kwargs, &rets.arg_block)

          if rets.cbresult
            external_call_result(rets.cbresult, cbres, answer_queue, rets.result_wrapper)
          end
        when WrappedException
          close_answer_queue(answer_queue, name)
          raise(*rets.exc)
        else
          close_answer_queue(answer_queue, name)
          return rets
        end
      end
    end

    private def close_answer_queue(answer_queue, name)
      answer_queue.close
      unless answer_queue.empty?
        rets = answer_queue.deq
        case rets
        when ExternalObjectCall
          if Proc === name
            raise InvalidAccess, "#{rets.objtype} can't be called through #{name.inspect}, since it already returned"
          else
            raise InvalidAccess, "#{rets.objtype} can't be called through method `#{name}', since it already returned"
          end
        else
          if Proc === name
            raise MultipleResults, "second result yielded for #{name.inspect} that already returned"
          else
            raise MultipleResults, "second result yielded for method `#{name}' that already returned"
          end
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

    # Wrap an object as ExternalObject.
    def €(object)
      Sanitizer.wrap_object(object, nil, self, nil)
    end

    def thread_finished(action)
      @mutex.synchronize do
        @running_actions.delete(action) or raise(ArgumentError, "unknown action has finished: #{action}")
        _update_action_threads_for_gc
      end
    end

    class ExternalObjectCall < Struct.new :object, :method, :args, :kwargs, :arg_block, :cbresult, :result_wrapper
      def proc?
        Proc === object
      end

      def objtype
        proc? ? "closure" : "method `#{method}'"
      end
    end

    def _external_object_call(object, method, name, args, kwargs, arg_block, cbresult, source_event_loop, call_context)
      result_wrapper = ArgumentWrapper.build(cbresult, name) if cbresult
      args = Sanitizer.sanitize_values(args, self, source_event_loop)
      kwargs = Sanitizer.sanitize_kwargs(kwargs, self, source_event_loop)
      arg_block = Sanitizer.sanitize_value(arg_block, self, source_event_loop)
      cb = ExternalObjectCall.new(object, method, args, kwargs, arg_block, cbresult, result_wrapper)

      if call_context
        # explicit call_context given
        if call_context.__answer_queue__.closed?
          raise InvalidAccess, "#{cb.objtype} #{"defined by `#{name}' " if name}was called with a call context that already returned"
        end
        call_context.__answer_queue__ << cb
      elsif @latest_answer_queue
        # proc called by a sync or yield call/proc context
        @latest_answer_queue << cb
      else
        raise InvalidAccess, "#{cb.objtype} #{"defined by `#{name}' " if name}was called by `#{@latest_call_name}', which must a sync_call, yield_call, sync_proc or yield_proc"
      end

      nil
    end

    def start_action(meth, name, args, &block)
      # Actions might not be tagged to a calling event scope
      source_event_loop = Thread.current.thread_variable_get(:__event_loop__)
      Thread.current.thread_variable_set(:__event_loop__, nil)

      qu = Queue.new

      new_thread = Thread.handle_interrupt(Exception => :never) do
        @threadpool.new do
          begin
            Thread.handle_interrupt(AbortAction => :on_blocking) do
              if meth.arity == args.length
                meth.call(*args, &block)
              else
                meth.call(*args, qu.deq, &block)
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
