[![Build Status Linux](https://travis-ci.com/larskanis/eventbox.svg?branch=master)](https://travis-ci.com/larskanis/eventbox)
[![Build status Windows](https://ci.appveyor.com/api/projects/status/tq397g0gfke1mcud/branch/master?svg=true)](https://ci.appveyor.com/project/larskanis/eventbox/branch/master)

# Eventbox

_Manage multithreading with the safety of event based programming_

{Eventbox} objects are event based and single threaded from the inside but thread safe and blocking from the outside.
Eventbox enforces a separation of code for event processing and code running blocking operations.
All code inside an {Eventbox} object is executed non-concurrently and hence must not do any blocking operations.

In the other hand all blocking operations can be executed in action threads spawned by the {Eventbox.action action} method type.
Communication between actions and event processing is done through ordinary method calls.

An important task of Eventbox is to avoid race conditions through shared data.
Such data races between internal and external objects are avoided through {Eventbox::Sanitizer filters} applied to all inputs and outputs.
That way {Eventbox} guarantees stable states while event processing without a need for any locks.

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
It can therefore be used to build well known multithread abstractions like a Queue class:

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
The key feature is the {Eventbox.yield_call} method definition.
It divides the single external call into two internal events: The event of the start of call and the event of releasing the call with a return value.
In contrast {Eventbox.async_call} defines a method which handles one event only - the start of the call.
The external call returns immediately, but can't return a value.

Seeing curly braces instead of links? Switch to the [API documentation](https://www.rubydoc.info/github/larskanis/eventbox/master).

The branch in `Queue#deq` shows a typical decision taking in Eventbox:
If the call can be processed immediately it yields the result, else wise the result is added to a list to be processes later.
It's important to check this list at each event which could signal the ability to complete the enqueued processing.
This is done in `Queue#enq` in the above example.

If you just need a queue it's better to stay at the Queue implementations of the standard library or [concurrent-ruby](https://github.com/ruby-concurrency/concurrent-ruby).
However if you want to cancel items in the queue for example, you need more control about waiting items or waiting callers than common thread abstractions offer.
The same if you want to query and visualize the internal state of processing - that means the pending items in the queue.


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

Since Eventbox protects from data races, it's insignificant in which order events are emitted by an internal method and whether objects are changed after being sent.
It's therefore OK to set `@downloads` both before or after starting the action threads per `start_download` in `init`.


## Call types

Eventbox offers 3 call types for internal scope:

* {Eventbox.yield_call} defines a blocking or non-blocking method with return value. It is the most flexible call type.
* {Eventbox.sync_call} is a convenience version of yield_call for a non-blocking method with return value.
* {Eventbox.async_call} is a convenience version of yield_call for a non-blocking method without return value.

Seeing curly braces instead of links? Switch to the [API documentation](https://www.rubydoc.info/github/larskanis/eventbox/master).

Similary there are 3 types of proc objects which act as anonymous versions of the above method call types.

* {Eventbox#yield_proc} allocates a blocking or non-blocking proc object with a return value.
* {Eventbox#sync_proc} allocates a Proc object for a non-blocking piece of code with return value.
* {Eventbox#async_proc} allocates a Proc object for a non-blocking piece of code without return value.

There are also accessor methods usable as known from ordinary ruby objects: {Eventbox.attr_reader},  {Eventbox.attr_writer} and  {Eventbox.attr_accessor}.

{Eventbox.action Action} methods are very different to the above.
They run in parallel to all internal methods within their own thread.


## How does it work?

Eventbox distinguish between internal and external scope:

* Internal scope is within methods defined by {Eventbox.async_call}, {Eventbox.sync_call} or {Eventbox.yield_call}.
* External scope are all callers outside of the particular Eventbox object.
* External scope are also methods defined by {Eventbox.action}, although they can call object internal methods and although they reside within the same class.

At each change of the scope all passing objects are sanitized by the {Eventbox::Sanitizer}.
It protects the internal scope from data races and arbitrates between blocking and event based semantics.
This is done by copying or wrapping the objects conveniently as described in the {Eventbox::Sanitizer}.
That way internal methods never get an inconsistent state regardless of the activities of external threads.

However Eventbox doesn't protect external scope and action scope from threading issues.
External scope is recognized as only one common space.
External libraries and objects must be threadsafe on its own if used from different threads.
Protecting them is beyond the scope of Eventbox.


## When to use Eventbox?

Eventbox comes into action when things are getting more complicated or more customized.
For instance a module which shall distribute work orders to external processes with a noticeable startup time, several activation steps and different properties per process.
In such cases available abstractions don't fit well to the problem.
Eventbox helps to manage a consistent state about these running activities.
It also allows to query this state in a natural way, since states can be stored in plain ruby objects (arrays, hashs, etc) instead of specialized thread abstractions.

While not impossible to implement things per raw threads, mutexes and condition variables, it's pretty hard to do that right.
Most thread abstractions don't do deeper checks for wrong usage like data races.
Ruby doesn't (yet) have mechanisms to bind objects to threads.
There are no tools to verify correct usage of mutexes in ruby.
However threading errors are subtle, so you'll probably not notice mistakes, until going to production.

Due to Eventbox's checks and guaranties it's easier to verify and prove correctness of implementations running on top of it.
This was the primary main reason to develop this library.


## Comparison with other libraries

Eventbox doesn't try to implement IO or other blocking operations on top of the global event loop of a reactor model.
Instead it encourages the use of blocking operations and threads for things which should run in parallel, while still keeping the majority of code in safe internal methods written in a event based style.
Because IO is done in action threads, the only type of events handled by the object internal event loop are method calls received from actions or external calls.

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
