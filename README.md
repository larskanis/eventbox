[![Build Status Linux](https://travis-ci.com/larskanis/eventbox.svg?branch=master)](https://travis-ci.com/larskanis/eventbox)
[![Build status Windows](https://ci.appveyor.com/api/projects/status/tq397g0gfke1mcud/branch/master?svg=true)](https://ci.appveyor.com/project/larskanis/eventbox/branch/master)

# Eventbox

_Manage multithreading with the safety of event based programming_

{Eventbox} objects are event based from the inside but thread safe from the outside.
All code inside an {Eventbox} object is executed non-concurrently.
It must not do any blocking operations.
All blocking operations can be executed in action threads spawned by the {Eventbox.action action} method type.
Data races between internal and external objects are avoided through {Eventbox::ArgumentSanitizer filters} applied to all inputs and outputs.
That way {Eventbox} guarantees stable states without a need for any locks.

For better readability see the [API documentation](https://www.rubydoc.info/github/larskanis/eventbox/master).


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

{Eventbox} is an universal approach to build thread safe objects.
It can therefore be used to build well known mutithread abstractions like a Queue class:

```ruby
require "eventbox"
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
It has semantics like ruby's builtin Queue implementation:

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
The key feature is the {yield_call} method definition.
It divides the single external call into two internal events: The event of the start of call and the event of releasing the call with a return value.
In contrast {async_call} defines a method which handles one event only - the start of the call.
The external call returns immediately, but can't return a value.


### A more practical example

Let's continue with an example which shows how {Eventbox} is typically used.
The following class downloads a list of URLs in parallel.

```ruby
require "eventbox"
require "net/https"
require "open-uri"
require "pp"

# Build a new Eventbox based class, which makes use of a pool of two threads.
# This way the number of concurrent downloads is limited to 3.
class ParallelDownloads < Eventbox.with_options(threadpool: Eventbox::ThreadPool.new(3))

  # Called at ParallelDownloads.new just like Object#initialize in ordinary ruby classes
  # Yield calls get one additional argument and suspend the caller until result.yield is invoked
  yield_call def init(urls, result)
    @urls = urls
    @urls.each do |url|             # Start a download thread for each URL
      start_download(url)           # Start the download - the call returns immediately
    end
    # It's safe to set instance variables after start_download
    @downloads = {}                 # The result hash with all downloads
    @finished = result              # Don't return to the caller, but store result yielder for later
  end

  # Each call to an action method starts a new thread
  # Actions don't have access to instance variables.
  private action def start_download(url)
    data = OpenURI.open_uri(url)    # HTTP GET url
      .read(100).each_line.first    # Retrieve the first line but max 100 bytes
  rescue SocketError => err         # Catch any network errors
    download_finished(url, err)     # and store it in the result hash
  else
    download_finished(url, data)    # ... or store the retrieved data when successful
  end

  # Called for each finished download
  private sync_call def download_finished(url, res)
    @downloads[url] = res           # Store the download result in the result hash
    if @downloads.size == @urls.size # All downloads finished?
      @finished.yield               # Finish ParallelDownloads.new
    end
  end

  attr_reader :downloads            # Threadsafe access to @download
end

urls = %w[
  http://ruby-lang.org
  http://ruby-lang.ooorg
  http://wikipedia.org
  http://torproject.org
  http://github.com
]

d = ParallelDownloads.new(urls)
pp d.downloads
```

This returns output like the following.
The order depends on the particular response time of the URL.

```ruby
{"http://ruby-lang.ooorg"=>#<SocketError: Failed to open TCP connection to ruby-lang.ooorg:80 (getaddrinfo: Name or service not known)>,
 "http://wikipedia.org"=>"<!DOCTYPE html>\n",
 "http://torproject.org"=>"<div class=\"eoy-background\">\n",
 "http://ruby-lang.org"=>"<!DOCTYPE html>\n",
 "http://github.com"=>"\n"}
```

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
