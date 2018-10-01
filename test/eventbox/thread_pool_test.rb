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
  end
end
