require_relative "../test_helper"

class EventboxActionTest < Minitest::Test

  eval_file "eventbox/action_test_collection.rb"

  def test_100_init_with_pending_action
    100.times.map do
      TestInitWithPendingAction.new
    end.each(&:shutdown!)
  end

  def test_shutdown
    GC.start    # Try to sweep other pending threads
    sleep 0.1

    c1 = Thread.list.length
    eb = TestInitWithPendingAction.new
    c2 = Thread.list.length
    assert_equal c1+1, c2, "There should be a new thread"

    eb.shutdown!

    c3 = Thread.list.length
    assert_equal c1, c3, "The new thread should be removed"
  end

end
