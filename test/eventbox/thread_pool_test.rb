require_relative "../test_helper"

class EventboxThreadBoxTest < Minitest::Test
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
    tp.shutdown!
  end

  def test_join_in_request
    tp = Eventbox::ThreadPool.new(1)
    assert_elapsed_fake_time(2) do
      tp.new do
        Kernel.sleep 1
      end
      th = tp.new do
        Kernel.sleep 1
      end
      th.join
    end
    tp.shutdown!
  end

  def test_join_in_running
    tp = Eventbox::ThreadPool.new(3)
    assert_elapsed_fake_time(1) do
      th = tp.new do
        Kernel.sleep 1
      end
      Thread.pass
      th.join
    end
    tp.shutdown!
  end

  def test_join_after_finished
    tp = Eventbox::ThreadPool.new(3)
    assert_elapsed_fake_time(1) do
      th = tp.new do
      end
      Kernel.sleep 1
      th.join
    end
    tp.shutdown!
  end
end
