[![Build Status Linux](https://travis-ci.com/larskanis/eventbox.svg?branch=master)](https://travis-ci.com/larskanis/eventbox)
[![Build status Windows](https://ci.appveyor.com/api/projects/status/tq397g0gfke1mcud/branch/master?svg=true)](https://ci.appveyor.com/project/larskanis/eventbox/branch/master)

# Eventbox

_Manage multithreading with the safety of event based programming_

{Eventbox} objects are event based and single threaded from the inside but thread-safe and blocking from the outside.
Eventbox enforces a separation of code for event processing and code running blocking operations.
Code inside an {Eventbox} object is executed non-concurrently and hence shouldn't do any blocking operations.

On the other hand all blocking operations can be executed in action threads spawned by the {Eventbox.action action} method type.
Communication between actions and event processing is done through ordinary method calls.

An important task of Eventbox is to avoid race conditions through shared data.
Such data races between event scope and external/action scope are avoided through {Eventbox::Sanitizer filters} applied to all inputs and outputs.
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

{Eventbox} is an universal approach to build thread-safe objects.
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

Although there are no mutex or condition variables in use, the implementation is guaranteed to be thread-safe.
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

Since Eventbox protects from data races, it's insignificant in which order events are emitted by an event scope method and whether objects are changed after being sent.
It's therefore OK to set `@downloads` both before or after starting the action threads per `start_download` in `init`.


## Method types

### Event Scope

Eventbox offers 3 different types of external callable methods:

* {Eventbox.yield_call yield_call} defines a blocking or non-blocking method with return value.
  It is the most flexible call type.
* {Eventbox.sync_call sync_call} is a convenience version of `yield_call` for a non-blocking method with return value.
* {Eventbox.async_call async_call} is a convenience version of `yield_call` for a non-blocking method without return value.

They can be defined with `private`, `protected` or `public` visibility.
The method body is referred to as "event scope" of a given Eventbox object.
Code in the event scope is based on an event driven programming style where events are signaled by method calls or by callback functions.

The event scope shouldn't be used to do blocking operations.
There is no hard criteria for what is considered a blocking operation, but since event scope methods of one object don't run concurrently, it decreases the overall responsiveness of the Eventbox instance.
If the processing time of an event scope method or block exceeds the limit of 0.5 seconds, a warning is print to STDERR.
This limit can be changed by {Eventbox.with_options}.

In additoin there are accessor methods usable as known from ordinary ruby objects: {Eventbox.attr_reader attr_reader},  {Eventbox.attr_writer attr_writer} and  {Eventbox.attr_accessor attr_accessor}.
They allow thread-safe access to instance variables.

Beside {Eventbox.async_call async_call}, {Eventbox.sync_call sync_call} and {Eventbox.yield_call yield_call} methods it's possible to define plain `private` methods, since they are not accessible externally.
However any plain `public` or `protected` methods within Eventbox classes are rejected.

### Action Scope

{Eventbox.action Action} methods are very different from the above.
They run concurrently to all event scope methods within their own thread.
Although actions reside within the same class they don't share instance variables with the event scope.
However they can safely call all instance methods.
The method body is referred to as "action scope".

Eventbox doesn't provide specific methods for asynchronous IO, but relies on ruby's builtin methods or gems for this purpose.
The intention is, that IO or any other blocking calls are done through {Eventbox.action action} methods.
In contrast to event scope, they should not share any data with other actions or threads.
Instead a shared-nothing approach is the recommended way to build actions.
That means, that all data required for one particular action call, should be passed as arguments, but nothing more.
And all data generated by the action should be passed as arguments back to event scope methods and the outcome should be managed there.

Some data shall just be managed as reference in some scope without being accessed there.
Or it is passed through a given scope only.
In such cases it can be marked as {Eventbox#shared_object shared_object}.

### External scope

All code outside of event scope or action scope is referred to as "external scope".


## Block and Proc types

Similary to the 3 method calls above there are 3 types of proc objects which act as anonymous counterparts of the method call types.

* {Eventbox#yield_proc yield_proc} allocates a blocking or non-blocking proc object with a return value.
  It is the most flexible proc type.
* {Eventbox#sync_proc sync_proc} is a convenience version of yield_proc for a non-blocking code block with return value.
* {Eventbox#async_proc async_proc} is a convenience version of yield_proc for a non-blocking code block without return value.

These proc objects can be created within event scope, can be passed to external scope and called from there.

The other way around - Proc objects or blocks which are defined in external or action scope - can be passed to event scope.
Such a Proc object is wrapped as a {Eventbox::ExternalProc} object within the event scope.
There it can be called as usual - however the execution of the proc doesn't stall the Eventbox object.
Instead the event scope method is executed until its end, while the block is executed within the thread which has called the current event scope method.
Optionally the block can be called with a completion block as the last argument, which is called with the result of the external proc when it has finished.


## What is safe and what isn't?

At each transition of the scope all passing objects are sanitized by the {Eventbox::Sanitizer}.
It protects the event scope from data races and arbitrates between blocking and event based semantics.
This is done by copying or wrapping the objects conveniently as described in the {Eventbox::Sanitizer}.
That way event scope methods never get an inconsistent state regardless of the activities of external threads.

Obviously it's not safe to do things like using `send` to call private methods from external, access instance variables per `instance_variable_set` or use global variables in a multithreading context.
Such rough ways of communication with an Eventbox object are surely neither recommended nor supported.
Other than these the event scope of an Eventbox instance is pretty well protected against accident mistakes.

However there's a catch which needs to take note of:
It is not restricted to access any constants from event scope.
Therefore it's possible to call for example `Thread.new` within the event scope.
Unsurprisingly is a very bad idea, since the provided block is called with no synchronization and can therefore lead to all kind of threading issues.
It would be safe to call `Thread.new` with an {Eventbox#async_proc async_proc}, however since the proc is not allowed to do any blocking operations, it's recommended to use an {Eventbox.action action} method definition instead to spawn threads.

Also note that Eventbox doesn't protect external scope or action scope from threading issues.
The external scope is recognized as one common space.
External libraries and objects must be thread-safe on its own if used from different threads in external or action scope.
Protecting them is beyond the scope of Eventbox.


## Time based events

It's possible to generate a timer event by stating an action with a `sleep` and subsequent call to an {Eventbox.async_call async_call} method.
However that's not very convenient.
Therefore Eventbox provides a dedicated {Eventbox::Timer timer module} for simple timer functions.
It can be included into Eventbox classes by:

```ruby
  include Eventbox::Timer
```

It offers {Eventbox::Timer#timer_after} and {Eventbox::Timer#timer_every} functions to schedule blocks to be called.


## Derived classes and mixins

Eventbox classes can be derived like ordinary ruby classes - there are no restrictions specific to Eventbox.
Methods of base classes can be called by `super`.
All classes of the hierarchy share the same instance variables like ordinary ruby objects.
Only {Eventbox.action action} methods use their own variable space.

It's also possible to mix a module into the Eventbox class.
See the description of {Eventbox::Boxable} for how it works.


## When to use Eventbox?

Eventbox comes into action when things are getting more complicated or more customized.
For instance a module which shall distribute work orders to external processes.
When it shall visualize the progress and allow cancellation of orders, available abstractions don't fit well to the problem.

In such a case Eventbox helps to manage a consistent state about these running activities.
It also allows to query this state in a natural way, since states can be stored in plain ruby objects (arrays, hashs, etc) instead of specialized thread abstractions.

While not impossible to implement things per raw threads, mutexes and condition variables, it's pretty hard to do that right.
There are no tools to verify correct usage of mutexes or other threading abstractions in ruby.
However threading errors are subtle, so you'll probably not notice mistakes, until going to production.

Due to Eventbox's checks and guaranties it's easier to verify and prove correctness of implementations running on top of it.
This was the primary motivation to develop this library.


## Comparison with other threading abstractions

### The Actor model

Eventbox is kind of advancement of the well known [actor model](https://en.wikipedia.org/wiki/Actor_model).
While the actor model uses explicit message passing, Eventbox relies on method and closure calls, which makes it much more natural to use.
Unlike an actor, Eventbox doesn't start a thread per object by default, but uses the thread of the caller to execute non-blocking code.
Instead it can create and interrupt in-object private threads in form of actions to be used for blocking operations.

### Internal state

Eventbox keeps all instance variables in a consistent state as a whole.
This is an important difference to [thread-safe collections](https://github.com/ruby-concurrency/concurrent-ruby#thread-safe-value-objects-structures-and-collections) like `Concurrent::Hash`.
They mislead the developer to believe that a module is thread-safe when it's just using these classes.

Unfortunately this is often wrong: They require a lot of experience to avoid mistakes through non-atomic updates, non-atomic test-and-set operations or race-conditions through using several thread-safe objects in combination (although a consistent state is only managed on a per object base).

### Data races

Most thread abstractions don't do deeper checks for wrong usage of data.
In particular they don't protect from data races like Eventbox does.
Ruby doesn't (yet) have mechanisms to bind objects to threads, so that there's no builtin safety.

### Blocking and non-blocking scope

Beside this, Eventbox has an explicit specification where blocking and where non-blocking code has to be executed and the compliance is monitored.
This ensures that events are processed in time regardless of the current state.
Such a specification is not enforced by most other threading abstractions and can quickly lead to delayed reactions in particular situations.


## Comparison with other async libraries

Eventbox doesn't try to implement IO or other blocking operations on top of a global event loop.
Instead it encourages the use of blocking operations and threads for things which should run in parallel, while keeping the management code in safe internal methods written in an event based style.
Because IO is done in action threads, the only type of events handled by the event scope are method calls received from actions or external calls.
They are processed by a kind of event loop which runs one per Eventbox object.

This is in contrast to libraries like [async](https://github.com/socketry/async), [EventMachine](https://github.com/eventmachine/eventmachine) or [Celluloid](https://github.com/celluloid/celluloid) which provide dozens of IO wrappers.


## Eventbox performance

Eventbox is reasonably fast, but far from the performance of threading primitives implemented in [concurrent-ruby](https://github.com/ruby-concurrency/concurrent-ruby).
It is not written to minimize resource consumption or maximize performance or throughput.
Instead it is written to minimize race conditions and implementation complexity in a multithreaded environment.
It also does a lot of safety checks to support the developer.

So if your use case requires raw performance more than implementation safety, Eventbox is probably not the right tool.

Still there is lots of room for performance improvements in Eventbox, like faster method invocations or copy-on-write objects.
If there's a stronger interest in Eventbox performance, it's possible to source relevant parts out to a C extension.
The introduction of guilds in ruby will probably be helpful for Eventbox as well.


## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/larskanis/eventbox. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).


## Code of Conduct

Everyone interacting in the Eventbox project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/larskanis/eventbox/blob/master/CODE_OF_CONDUCT.md).
