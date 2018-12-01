require_relative "../test_helper"
require "socket"

class ExamplesServerTest < Minitest::Test
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

  def test_server
    10.times do |j|
      s = MyServer.new('localhost', 12345)

      resps = 10.times.map do
        Thread.new do
          TCPSocket.new('localhost', 12345).read
        end
      end.map(&:value)

      assert_equal 10.times.map{|i| "Hello #{i+1}"}.sort, resps.sort

      s.stop
      assert_raises(SystemCallError){ TCPSocket.new('localhost', 12345) }
    end
  end
end
