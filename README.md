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

See the following example:

    class Box1 < Eventbox
      # Define a method with deferred return value.
      yield_call def go(id, result)
        puts "go called: #{id} thread: #{Thread.current.object_id}"

        # Start a new thread to execute blocking functions.
        # Parameters are passed safely as copied or wrapped objects.
        action id, result, def wait(id, result)
          puts "action #{id} started thread: #{Thread.current.object_id}"
          sleep 1
          done(id, result)
          puts "action #{id} finished thread: #{Thread.current.object_id}"
        end
      end

      # Define a method with no return value.
      async_call def done(id, result)
        puts "done called: #{id} thread: #{Thread.current.object_id}"
        # Let fc.go return
        result.yield
      end
    end
    fc = Box1.new

    th = Thread.new do
      # Run 3 threads which call fc.go concurrently.
      3.times.map do |id|
        Thread.new do
          fc.go(id)
          puts "go returned: #{id} thread: #{Thread.current.object_id}"
        end
      end.map(&:value)
      # Let fc.run exit
      fc.exit_run
    end

    # Run the event loop of Box1
    fc.run

Running this takes one second and prints an output similar to this:

    go called: 1 thread: 56
    go called: 0 thread: 56
    go called: 2 thread: 56
    action 1 started thread: 54
    action 0 started thread: 36
    action 2 started thread: 16
    action 1 finished thread: 54
    done called: 1 thread: 56
    go returned: 1 thread: 86
    action 2 finished thread: 16
    done called: 2 thread: 56
    action 0 finished thread: 36
    done called: 0 thread: 56
    go returned: 2 thread: 72
    go returned: 0 thread: 04

The thread `object_id` above is shortened for better readability.
Although `go` and `done` are called from different threads (86, 72, 04), they are enqueued into the event loop of Box1 and subsequently executed by the main thread (56).
Since all calls are handled by one thread internally, access to instance variables is safe without locks.
In contrast each call to `action` is executed by it's own thread (54, 36, 16).
All parameters passed to the thread are copied or securely wrapped and the action has with no access to local or instance variables.


## Comparison with other libraries

Eventbox doesn't try to implement IO or other blocking operations on top of the global event loop of a reactor model.
Instead it encourages the use of blocking operations and handles method calls as events to a boxed event loop of a single object.
This is in contrast to libraries like [async](https://github.com/socketry/async), [EventMachine](https://github.com/eventmachine/eventmachine) or [Celluloid](https://github.com/celluloid/celluloid).
Eventbox is reasonably fast, but is not written to minimize resource consumption or maximize performance.
Instead it is written to minimize race conditions and implementation complexity in a multithreaded environment.


## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/larskanis/eventbox. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Eventbox project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/larskanis/eventbox/blob/master/CODE_OF_CONDUCT.md).
