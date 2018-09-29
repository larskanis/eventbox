require_relative "test_helper"

class EventboxTest < Minitest::Test

  def test_that_it_has_a_version_number
    assert_match(/\A\d+\.\d+\.\d+/, ::Eventbox::VERSION)
  end

  class TestBox < Eventbox
  end

  def test_default_options
    assert_equal({threadpool: Thread}, Eventbox.eventbox_options)
  end

  def test_with_options
    kl = TestBox.with_options(threadpool: Thread).with_options(www: 1)
    assert_equal "EventboxTest::TestBox{:threadpool=>Thread, :www=>1}", kl.inspect
    assert_equal({threadpool: Thread, www: 1}, kl.eventbox_options)
  end
end
