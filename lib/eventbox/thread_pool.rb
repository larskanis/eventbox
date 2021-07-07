# frozen-string-literal: true

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

    # Representation of a work task given as block to ThreadPool.new
    class PoolThread < Eventbox
      # It has 3 implicit states: enqueued, running, finished
      # Variables for state "enqueued": @block, @joins, @signals
      # Variables for state "running": @joins, @action
      # Variables for state "finished": -
      # Variables unused in this state are set to `nil`.
      async_call def init(block, action)
        @block = block
        @joins = []
        @signals = block ? [] : nil
        @action = action
      end

      async_call def raise(*args)
        # Eventbox::AbortAction would shutdown the thread pool.
        # To stop the borrowed thread only remap to Eventbox::ThreadPool::AbortAction .
        args[0] = AbortAction if args[0] == Eventbox::AbortAction

        if a=@action
          # The task is running -> send the signal to the thread
          a.raise(*args)
        elsif s=@signals
          # The task is still enqueued -> add the signal to the request
          s << args
        end
      end

      # Belongs the current thread to this action.
      sync_call def current?
        if a=@action
          a.current?
        else
          false
        end
      end

      yield_call def join(result)
        if j=@joins
          j << result
        else
          # action has already finished
          result.yield
        end
      end

      async_call def terminate
        @action.abort
      end

      # @private
      async_call def __start__(action, input)
        # Send the block to the start_pool_thread as result of next_job
        input.yield(self, @block)

        # Send all accumulated signals to the action thread
        @signals.each do |sig|
          action.raise(*sig)
        end

        @action = action
        @signals = nil
        @block = nil
      end

      # @private
      async_call def __finish__
        @action = nil
        @joins.each(&:yield)
        @joins = nil
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
      while true
        req, bl = next_job(action)
        begin
          Thread.handle_interrupt(AbortAction => :on_blocking) do
            bl.yield
          end
        rescue AbortAction
          # The pooled action was aborted, but the thread keeps going
        ensure
          req.__finish__
        end

        # Discard all interrupts which are too late to arrive the running action
        while Thread.pending_interrupt?
          begin
            Thread.handle_interrupt(Exception => :immediate) do
              sleep # Aborted by the exception
            end
          rescue Eventbox::AbortAction
            raise # The thread-pool was requested to shutdown
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
        req.__start__(action, input)
      end
    end

    sync_call def new(&block)
      if @jobless.empty?
        # No free thread -> enqueue the request
        req = PoolThread.new(block, nil)
        @requests << req

        # Try to release some actions by the GC
        if @run_gc_when_busy
          @run_gc_when_busy = false # Start only one GC run
          gc_start
        end
      else
        # Immediately start the block
        action, input = @jobless.shift
        req = PoolThread.new(nil, action)
        input.yield(req, block)
      end

      req
    end

    private action def gc_start
      GC.start
    ensure
      gc_finished
    end

    private async_call def gc_finished
      @run_gc_when_busy = true
    end

    def inspect
      "#<#{self.class}:#{self.object_id} @requests=#{@requests.length} @jobless=#{@jobless.length} @run_gc_when_busy=#{@run_gc_when_busy.inspect}>"
    end
  end
end
