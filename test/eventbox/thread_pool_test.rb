require_relative "../test_helper"

class EventboxActionTest < Minitest::Test
  def test_number_of_threads
    tp = Eventbox::ThreadPool.new(3)

    q = Queue.new
    50.times do |i|
      tp.new do
        sleep 0.001
        q.enq [i, Thread.current.object_id]
      end
    end

    results = 50.times.map { q.deq }
    assert_equal 50.times.to_a, results.map(&:first).sort
    assert_equal 3, results.map(&:last).uniq.size
  end

  def test_100_actions
    ec = Eventbox.with_options(threadpool: Eventbox::ThreadPool.new(2))
    eb = Class.new(ec) do
      yield_call def init(result)
        @ids = []
        100.times do |id|
          action id, result, def adder(id, result)
            add(id, result)
          end
        end
      end

      async_call def add(id, result)
        @ids << id
        result.yield if @ids.size == 100
      end

      attr_reader :ids
    end.new

    assert_equal 100.times.to_a, eb.ids.sort
  end
end
