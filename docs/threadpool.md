The following class implements a thread-pool with a fixed number of threads to be borrowed by the `pool` method.
It shows how the action method `start_pool_thread` makes use of the private yield_call `next_job` to query, wait for and retrieve an object from the event scope.

This kind of object is the block that is given to `pool`.
Although all closures (blocks, procs and lambdas) are wrapped in a way that allows safe calls from the event scope, it is just passed through to the action scope and retrieved as the result value of `next_job`.
When this happens, the wrapping is automatically removed, so that the pure block given to `pool` is called in `start_pool_thread`.

```ruby
class ThreadPool < Eventbox
  async_call def init(pool_size)
    @que = []                 # Initialize an empty job queue
    @jobless = []             # Initialize the list of jobless action threads

    pool_size.times do        # Start up x action threads
      start_pool_thread
    end
  end

  # The action call returns immediately, but spawns a new thread.
  private action def start_pool_thread
    while bl=next_job     # Each new thread waits for a job to be pooled
      bl.call             # Execute the external job enqueued by `pool`
    end
  end

  # Get the next job or wait for one
  # The method is private, so that it's accessible in start_pool_thread action but not externally
  private yield_call def next_job(result)
    if @que.empty?            # No job pooled?
      @jobless << result      # Enqueue the action thread to the list of jobless workers
    else                      # Already pooled jobs?
      result.yield @que.shift # Take the oldest job and let next_job return with this job
    end
  end

  # Enqueue a new job
  async_call def pool(&block)
    if @jobless.empty?        # No jobless thread available?
      @que << block           # Append the external block as job into the queue
    else                      # A thread is waiting?
      @jobless.shift.yield block  # Take one thread and let next_job return the given job
    end                           # so that it is processed by the pool_thread action above
  end
end
```

This `ThreadPool` can be used like so:

```ruby
tp = ThreadPool.new(3)  # Create a thread pool with 3 action threads
5.times do |i|          # Start 5 jobs concurrently
  tp.pool do            # pool never blocks, but enqueues jobs when no free thread is available
    sleep 1             # The mission of each job: Wait for 1 second (3 jobs concurrently)
    p [i, Thread.current.object_id]
  end
end

# It gives something like the following output after 1 second:
[2, 47030774465880]
[1, 47030775602740]
[0, 47030774464940]
# and something like this after one more seconds:
[3, 47030775602740]
[4, 47030774465880]
```

Eventbox's builtin thread-pool {Eventbox::ThreadPool} is implemented on top of Eventbox similar to the above.
In addition there are various battle proof implementations of thread-pools such a these in [concurrent-ruby](https://github.com/ruby-concurrency/concurrent-ruby), which are faster and more feature rich than the above.

However Eventbox comes into play when things are getting more complicated or more customized.
Imagine the thread-pool has to schedule it's tasks not just to cheep threads, but to more expensive or more constraint resources.
In such cases available abstractions don't fit well to the problem.
Instead the above example can be used as a basis for your own extensions.
