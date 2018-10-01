class Eventbox
  class ThreadPool < Eventbox
    class AbortAction < RuntimeError; end

    class PoolThread < Eventbox
      async_call def init(rid, pool)
        @rid = rid
        @pool = pool
      end

      async_call def raise(*args)
        # Eventbox::AbortAction would shutdown the thread pool.
        # To stop the borrowed thread only remap to Eventbox::ThreadPool::AbortAction .
        args[0] = AbortAction if args[0] == Eventbox::AbortAction
        @pool.raise(@rid, *args)
      end
    end

    Request = Struct.new :block, :rid, :signals
    Running = Struct.new :block, :rid, :action

    async_call def init(pool_size, run_gc_when_busy: false)
      @jobless = []
      @rid = 0
      @actions = []
      @requests = []
      @running = Array.new(pool_size, Running.new)
      @run_gc_when_busy = run_gc_when_busy

      pool_size.times do |aid|
        a = pool_thread(aid)

        @actions[aid] = a
      end
    end

    action def pool_thread(aid)
      while bl=next_job(aid)
        begin
          Thread.handle_interrupt(AbortAction => :on_blocking) do
            bl.yield
          end
        rescue AbortAction
        end
      end
    end

    protected yield_call def next_job(aid, result)
      if @requests.empty?
        @jobless << [aid, result]
      else
        # Take the oldest request and send it to the calling action.
        req = @requests.shift
        result.yield(req.block)

        # Send all accumulated signals to the action thread
        ac = @actions[aid]
        req.signals.each do |sig|
          ac.raise(*sig)
        end

        @running[aid] = Running.new(req.block, req.rid, ac)
      end
    end

    sync_call def new(&block)
      @rid += 1
      if @jobless.empty?
        # No free thread -> enqueue the request
        @requests << Request.new(block, @rid, [])

        # Try to release some actions by the GC
        GC.start if @run_gc_when_busy
      else
        # Immediately start the block
        aid, result = @jobless.shift
        result.yield(block)
        @running[aid] = Running.new(block, @rid, @actions[aid])
      end

      PoolThread.new(@rid, self)
    end

    async_call def raise(rid, *args)
      if run=@running.find{|r| r.rid == rid }
        # The task is running -> send the signal to the thread
        run.action.raise(*args)
      elsif req=@requests.find{|r| r.rid == rid }
        # The task is still enqueued -> add the signal to the request
        req.signals << args
      end
    end
  end
end
