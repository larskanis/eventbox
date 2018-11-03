class Eventbox
  # A pool of reusable threads for actions
  #
  # By default each call of an action method spawns a new thread and terminates the thread when the action is finished.
  # If there are many short lived action calls, creation and termination of threads can be a bottleneck.
  # In this case it is desireable to reuse threads for multiple actions.
  # This is what a threadpool is made for.
  #
  # A threadpool creates a fixed number of threads at startup and distributes all action calls to free threads.
  # If no free thread is available, the request in enqueued and processed in order.
  #
  # It is possible to use one threadpool for several {Eventbox} derivations and {Eventbox} instances at the same time.
  # However using a threadpool adds the risk of deadlocks, if actions depend of each other and the threadpool provides too less threads.
  # A threadpool can slow actions down, if too less threads are allocated, so that actions are enqueued.
  # On the other hand a threadpool can also slow processing down, if the threadpool allocates many threads at startup, but doesn't makes use of them.
  #
  # An Eventbox with associated {ThreadPool} can be created per {Eventbox.with_options}.
  # +num_threads+ is the number of allocated threads:
  #   EventboxWithThreadpool = Eventbox.with_options(threadpool: Eventbox::ThreadPool.new(num_threads))
  class ThreadPool < Eventbox
    class AbortAction < RuntimeError; end

    class PoolThread
      def initialize(rid, pool)
        @rid = rid
        @pool = pool
      end

      def raise(*args)
        # Eventbox::AbortAction would shutdown the thread pool.
        # To stop the borrowed thread only remap to Eventbox::ThreadPool::AbortAction .
        args[0] = AbortAction if args[0] == Eventbox::AbortAction
        @pool.raise(@rid, *args)
      end

      # Belongs the current thread to this action.
      def current?
        @pool.current?(@rid)
      end

      def join
        @pool.join(@rid)
      end
    end

    Request = Struct.new :block, :rid, :joins, :signals
    Running = Struct.new :rid, :joins, :action

    async_call def init(pool_size, run_gc_when_busy: false)
      @jobless = []
      @rid = 0
      @actions = []
      @requests = []
      @running = Array.new(pool_size, Running.new)
      @run_gc_when_busy = run_gc_when_busy

      pool_size.times do |aid|
        a = start_pool_thread(aid)

        @actions[aid] = a
      end
    end

    action def start_pool_thread(aid)
      while bl=next_job(aid)
        begin
          Thread.handle_interrupt(AbortAction => :on_blocking) do
            bl.yield
          end
        rescue AbortAction
        ensure
          action_finished(aid)
        end

        # Discard all interrupts which are too late to arrive the running action
        while Thread.pending_interrupt?
          begin
            Thread.handle_interrupt(Exception => :immediate) do
              sleep # Aborted by the exception
            end
          rescue Exception
          end
        end
      end
    end

    private yield_call def next_job(aid, input)
      if @requests.empty?
        @jobless << [aid, input]
      else
        # Take the oldest request and send it to the calling action.
        req = @requests.shift
        input.yield(req.block)

        # Send all accumulated signals to the action thread
        ac = @actions[aid]
        req.signals.each do |sig|
          ac.raise(*sig)
        end

        @running[aid] = Running.new(req.rid, req.joins, ac)
      end
    end

    private async_call def action_finished(aid)
      @running[aid].joins.each(&:call)
      @running[aid] = Running.new
    end

    sync_call def new(&block)
      @rid += 1
      if @jobless.empty?
        # No free thread -> enqueue the request
        @requests << Request.new(block, @rid, [], [])

        # Try to release some actions by the GC
        if @run_gc_when_busy
          @run_gc_when_busy = false # Start only one GC run
          gc_start
        end
      else
        # Immediately start the block
        aid, input = @jobless.shift
        input.yield(block)
        @running[aid] = Running.new(@rid, [], @actions[aid])
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

    sync_call def current?(rid)
      if run=@running.find{|r| r.rid == rid }
        run.action.current?
      else
        false
      end
    end

    yield_call def join(rid, result)
      run_or_req = @running.find{|r| r.rid == rid }  || @requests.find{|r| r.rid == rid }
      if run_or_req
        run_or_req.joins << result
      else
        # action has already finished
        result.yield
      end
    end

    private action def gc_start
      GC.start
    ensure
      gc_finished
    end

    private async_call def gc_finished
      @run_gc_when_busy = true
    end
  end
end
