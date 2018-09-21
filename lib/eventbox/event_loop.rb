class Eventbox
  class EventLoop
    include ArgumentSanitizer

    attr_reader :action_class

    def initialize(threadpool, meths, klass, weakbox)
      @threadpool = threadpool
      @action_threads = {}
      @ctrl_thread = nil
      @mutex = Mutex.new
      @shutdown = false

      # When called from action method, this class is used as execution environment for the newly created thread.
      # All calls to public methods are passed to the calling instance.
      @action_class = Class.new(klass) do
        # Forward method calls.
        meths.each do |fwmeth|
          define_method(fwmeth) do |*fwargs, &fwblock|
            weakbox.send(fwmeth, *fwargs, &fwblock)
          end
        end
      end
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
#       warn "shutdown called for object #{object_id}"

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
        result = nil
        box.send("__#{name}__", *sanity_after_queue(args), proc do |*resu|
          raise MultipleResults, "received multiple results for method `#{name}'" if result
          result = resu
          resu = return_args(resu)
          resu = sanity_before_queue(resu)
          answer_queue << resu
        end, &sanity_after_queue(block))
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
          rescue AbortAction => err
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
