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

    # External representation of a work task given as block to ThreadPool.new
    class PoolThread
      def initialize(request, pool)
        @request = request
        @pool = pool
      end

      def raise(*args)
        # Eventbox::AbortAction would shutdown the thread pool.
        # To stop the borrowed thread only remap to Eventbox::ThreadPool::AbortAction .
        args[0] = AbortAction if args[0] == Eventbox::AbortAction
        @pool.raise(@request, *args)
      end

      # Belongs the current thread to this action.
      def current?
        @pool.current?(@request)
      end

      def join
        @pool.join(@request)
      end
    end

    async_call def init(pool_size, run_gc_when_busy: false)
      @jobless = []
      @requests = []
      @run_gc_when_busy = run_gc_when_busy

      pool_size.times do
        start_pool_thread
      end
    end

    action def start_pool_thread(action)
      loop do
        req, bl = next_job(action)
        begin
          Thread.handle_interrupt(AbortAction => :on_blocking) do
            bl.yield
          end
        rescue AbortAction
        ensure
          request_finished(req)
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

    private yield_call def next_job(action, input)
      if @requests.empty?
        @jobless << [action, input]
      else
        # Take the oldest request and send it to the calling action.
        req = @requests.shift
        input.yield(req, req.block)

        # Send all accumulated signals to the action thread
        req.signals.each do |sig|
          action.raise(*sig)
        end

        req.action = action
        req.signals = nil
        req.block = nil
      end
    end

    private async_call def request_finished(req)
      req.joins.each(&:call)
      req.joins = nil
      req.action = nil
    end

    # Internal representation of a PoolThread
    #
    # It has 3 states: enqueued, running, finished
    # Members for state "enqueued": block, joins, signals
    # Members for state "running": joins, action
    # Members for state "finished": -
    # Unused members are set to `nil`.
    Request = Struct.new :block, :joins, :signals, :action

    sync_call def new(&block)
      if @jobless.empty?
        # No free thread -> enqueue the request
        req = shared_object(Request.new(block, [], []))
        @requests << req

        # Try to release some actions by the GC
        if @run_gc_when_busy
          @run_gc_when_busy = false # Start only one GC run
          gc_start
        end
      else
        # Immediately start the block
        action, input = @jobless.shift
        req = shared_object(Request.new(nil, [], nil, action))
        input.yield(req, block)
      end

      PoolThread.new(req, self)
    end

    async_call def raise(req, *args)
      if req.action
        # The task is running -> send the signal to the thread
        req.action.raise(*args)
      elsif req.signals
        # The task is still enqueued -> add the signal to the request
        req.signals << args
      end
    end

    sync_call def current?(req)
      if req.action
        req.action.current?
      else
        false
      end
    end

    yield_call def join(req, result)
      if req.joins
        req.joins << result
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
