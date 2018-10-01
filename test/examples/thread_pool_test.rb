require_relative "../test_helper"

class ExamplesThreadPoolTest < Minitest::Test
  class TestThreadPool < Eventbox
    async_call def init(pool_size)
      @que = []
      @jobless = []

      pool_size.times do
        pool_thread
      end
    end

    action def pool_thread
      while bl=next_job
        bl.yield
      end
    end

    protected yield_call def next_job(result)
      if @que.empty?
        @jobless << result
      else
        result.yield @que.shift
      end
    end

    async_call def pool(&block)
      if @jobless.empty?
        @que << block
      else
        @jobless.shift.yield block
      end
    end
  end

  def test_thread_pool
    tp = TestThreadPool.new(3)

    q = Queue.new
    50.times do |i|
      tp.pool do
        sleep 0.001
        q.enq [i, Thread.current.object_id]
      end
    end

    results = 50.times.map { q.deq }
    assert_equal 50.times.to_a, results.map(&:first).sort
    assert_equal 3, results.map(&:last).uniq.size
  end
end
