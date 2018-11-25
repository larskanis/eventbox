require_relative "../test_helper"

class ExamplesQueueTest < Minitest::Test
  class TestQueue < Eventbox
    async_call def init
      @que = []
      @waiting = []
    end

    async_call def enq(€value)
      @que << €value
      if w=@waiting.shift
        w.yield @que.shift
      end
    end

    yield_call def deq(result)
      if @que.empty?
        @waiting << result
      else
        result.yield @que.shift
      end
    end
  end

  def test_queue
    q = TestQueue.new

    # Start two threads which enqueues values
    2.times do |s|
      Thread.new do
        500.times do |i|
          q.enq(2 * i + s)
        end
        q.enq nil
      end
    end

    # Start two thread which fetch values concurrently
    l1, l2 = 2.times.map do
      Thread.new do
        l = []
        while v=q.deq
          l << v
        end
        l
      end
    end.map(&:value)

    assert_operator 1..999, :===, l1.size
    assert_operator 1..999, :===, l2.size
    assert_equal 1000.times.to_a, (l1 + l2).sort
  end
end
