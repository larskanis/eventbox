[![Build Status Linux](https://travis-ci.com/larskanis/eventbox.svg?branch=master)](https://travis-ci.com/larskanis/eventbox)
[![Build status Windows](https://ci.appveyor.com/api/projects/status/tq397g0gfke1mcud/branch/master?svg=true)](https://ci.appveyor.com/project/larskanis/eventbox/branch/master)

# Eventbox

_Manage multithreading with the safety of event based programming_

Eventbox objects are event based from the inside but thread safe from the outside.
All code inside an Eventbox object is executed non-concurrently.
It must not do any blocking operations.
All blocking operations can be executed in action threads spawned by the `action` method.
Data races between internal and external objects are avoided through filters applied to all inputs and outputs.
That way Eventbox guarantees stable states without a need for any locks.

## Requirements

* Ruby-2.3 or newer or
* JRuby 9.1 or newer

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'eventbox'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install eventbox

## Usage

Let's build a Queue class:

```ruby
class Queue < Eventbox
  # Called at Queue.new just like Object#initialize in ordinary ruby classes
  async_call def init
    @que = []      # List of values waiting for being fetched by deq
    @waiting = []  # List of blocking deq calls waiting for new values to be pushed by enq
  end

  # Push a value to the queue and return the next value by the next waiting deq call
  async_call def enq(value)
    @que << value         # Push a value to the queue
    if w=@waiting.shift
      w.yield @que.shift  # Let one waiting deq call return with the next value from the queue
    end
  end

  # Fetch a value from the queue or suspend the caller until a value has been enqueued
  yield_call def deq(result)
    if @que.empty?
      @waiting << result       # Don't return a value now, but enqueue the request as waiting
    else
      result.yield @que.shift  # Immediately return the next value from the queue
    end
  end
end
```
It can be used just like ruby's builtin Queue implementation:

```ruby
q = Queue.new
Thread.new do
  5.times do |i|
    q.enq i      # Enqueue integers 0 to 5
  end
end

5.times do
  p q.deq        # Fetch and print 5 integers from the queue
end

# It gives the following output:
0
1
2
3
4
```

Although there are no mutex or condition variables in use, the implementation is guaranteed to be threadsafe.
The key feature is the `yield_call` method definition.
It divides the single external call into two internal events: The event of the start of call and the event of releasing the call with a return value.
In contrast `async_call` defines a method which handles one event only - the start of the call.
The external call returns immediately, but can't return a value.


### Another example: ThreadPool

The following class implements a thread pool with a fixed number of threads to be used by the `pool` method.

```ruby
class ThreadPool < Eventbox
  async_call def init(pool_size)
    @que = []                 # Initialize an empty job queue
    @jobless = []             # Initialize the list of jobless action threads

    pool_size.times do        # Start up x action threads
      pool_thread
    end
  end

  private action def pool_thread  # The action call returns immediately, but spawns a new thread
    while bl=next_job     # Each new thread waits for a job to be pooled
      bl.yield            # Execute the external job enqueued by `pool`
    end
  end

  # Get the next job or wait for one
  # The method is private, so that it's accessible in the pool_thread action but not externally
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

This ThreadPool can be used like so:

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

There are various battle proof implementations of multithreaded primitives, which are probably faster and more feature rich than the above.
See [concurrent-ruby](https://github.com/ruby-concurrency/concurrent-ruby) for a great collection of threading abstractions.

### When to use Eventbox?

Eventbox comes into action when things are getting more complicated or more customized.
Say a ThreadPool like challenge, but for virtual machines with a noticeable startup time, several activation steps and different properties per VM.
In such cases available abstractions don't fit well to the problem.
And while not impossible to implement things per mutexes and condition variables, it's pretty hard to do that right.
But if you don't do it right, you'll probably not notice that, until going to production.


## Comparison with other libraries

Eventbox doesn't try to implement IO or other blocking operations on top of the global event loop of a reactor model.
Instead it encourages the use of blocking operations and threads.
The only type of events handled by the object internal event loop are method calls.

This is in contrast to libraries like [async](https://github.com/socketry/async), [EventMachine](https://github.com/eventmachine/eventmachine) or [Celluloid](https://github.com/celluloid/celluloid).
Eventbox is reasonably fast, but is not written to minimize resource consumption or maximize performance or throughput.
Instead it is written to minimize race conditions and implementation complexity in a multithreaded environment.
It also does a lot of safety checks to support the developer.


## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/larskanis/eventbox. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Eventbox project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/larskanis/eventbox/blob/master/CODE_OF_CONDUCT.md).
