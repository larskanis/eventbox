## A TCP server implementation with tracking of startup and shutdown

Race-free server startup and shutdown can be a tricky task.
The following example illustrates, how a TCP server can be started and interrupted properly.

For startup it makes use of {Eventbox::CompletionProc yield} and {Eventbox::CompletionProc#raise} to complete `MyServer.new` either successfully or with the forwarded exception raised by `TCPServer.new`.

For the shutdown it makes use of {Eventbox::Action#raise} to send a `Stop` signal to the blocking `accept` method.
The `Stop` instance carries the {Eventbox::CompletionProc} which is used to signal that the shutdown has finished by returning from `MyServer#stop`.

```ruby
require "eventbox"
require "socket"

class MyServer < Eventbox
  yield_call def init(bind, port, result)
    @count = 0
    @server = start_serving(bind, port, result)   # Start an action to handle incomming connections
  end

  action def start_serving(bind, port, init_done)
    serv = TCPServer.new(bind, port)
  rescue => err
    init_done.raise err        # complete MyServer.new with an exception
  else
    init_done.yield            # complete MyServer.new without exception

    loop do                    # accept all connection requests until Stop is received
      begin
        # enable interruption by the Stop class for the duration of the `accept` call
        conn = Thread.handle_interrupt(Stop => :on_blocking) do
          serv.accept          # wait for the next connection request come in
        end
      rescue Stop => st
        serv.close
        st.stopped.yield       # let MyServer#stop return
        break                  # and exit the action
      else
        MyConnection.new(conn, self)  # Handle each client by its own instance
      end
    end
  end

  # A simple example for a shared resource to be used by several threads
  sync_call def count
    @count += 1                # atomically increment the counter
  end

  yield_call def stop(result)
    # Don't return from `stop` externally, but wait until the server is down
    @server.raise(Stop.new(result))
  end

  class Stop < RuntimeError
    def initialize(stopped)
      @stopped = stopped
    end
    attr_reader :stopped
  end
end

# Each call to `MyConnection.new` starts a new thread to do the communication.
class MyConnection < Eventbox
  action def init(conn, server)
    conn.write "Hello #{server.count}"
  ensure
    conn.close         # Don't wait for an answer but just close the client connection
  end
end
```

The server can now be started like so.

```ruby
s = MyServer.new('localhost', 12345)  # Open a TCP socket

10.times.map do                       # run 10 client connections in parallel
  Thread.new do
    TCPSocket.new('localhost', 12345).read
  end
end.each { |th| p th.value }          # and print their responses

s.stop                                # shutdown the server socket
```

It prints some output like this:

```ruby
"Hello 2"
"Hello 1"
"Hello 7"
"Hello 8"
"Hello 3"
"Hello 9"
"Hello 5"
"Hello 6"
"Hello 4"
"Hello 10"
```
