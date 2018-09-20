[![Build Status Linux](https://travis-ci.com/larskanis/eventbox.svg?branch=master)](https://travis-ci.com/larskanis/eventbox)
[![Build status Windows](https://ci.appveyor.com/api/projects/status/tq397g0gfke1mcud/branch/master?svg=true)](https://ci.appveyor.com/project/larskanis/eventbox/branch/master)

# Eventbox

_Manage multithreading with the safety of event based programming_

Eventbox objects are event based from the inside but thread safe from the outside.
All code inside an Eventbox object is executed sequentially by a single thread.
So it shouldn't do any blocking operations.
All blocking operations can be executed in action threads.
Data races are avoided through filters applied to all inputs and outputs.
That way Eventbox guarantees stable objects without a need for any locks.

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

Let's build a threadsafe Queue class:

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

Although there are no mutex or condition variables in use, the implementation is threadsafe.


## Comparison with other libraries

Eventbox doesn't try to implement IO or other blocking operations on top of the global event loop of a reactor model.
Instead it encourages the use of blocking operations and threads.
The only type of events handled by the object internal event loop are method calls.

This is in contrast to libraries like [async](https://github.com/socketry/async), [EventMachine](https://github.com/eventmachine/eventmachine) or [Celluloid](https://github.com/celluloid/celluloid).
Eventbox is reasonably fast, but is not written to minimize resource consumption or maximize performance.
Instead it is written to minimize race conditions and implementation complexity in a multithreaded environment.


## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/larskanis/eventbox. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Eventbox project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/larskanis/eventbox/blob/master/CODE_OF_CONDUCT.md).
