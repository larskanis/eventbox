Race-free server startup and shutdown can be a tricky task.
The following example illustrates, how a TCP server can be started and interrupted properly.

```ruby
require "eventbox"
require "socket"

class MyServer < Eventbox
  yield_call def init(bind, port, result)
    @count = 0
    @server = start_serving(bind, port, result)
  end

  action def start_serving(bind, port, init_done)
    serv = TCPServer.new(bind, port)
  rescue => err
    init_done.raise err
  else
    init_done.yield

    loop do
      begin
        conn = Thread.handle_interrupt(Stop => :on_blocking) do
          serv.accept
        end
      rescue Stop => st
        serv.close
        st.stopped.yield
        break
      else
        MyConnection.new(conn, self)
      end
    end
  end

  sync_call def count
    @count += 1
  end

  yield_call def stop(result)
    @server.raise(Stop.new(result))
  end

  class Stop < RuntimeError
    def initialize(stopped)
      @stopped = stopped
    end
    attr_reader :stopped
  end
end

class MyConnection < Eventbox
  action def init(conn, server)
    conn.write "Hello #{server.count}"
  ensure
    conn.close
  end
end
```

The server can now be started like so.

```ruby
s = MyServer.new('localhost', 12345)

10.times.map do
  Thread.new do
    TCPSocket.new('localhost', 12345).read
  end
end.each { |th| p th.value }

s.stop
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
