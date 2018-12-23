require_relative "../test_helper"

class EventboxSerializeTest < Minitest::Test
  def test_serialize_simple
    eb = SimpleBox.new([1,2,3])

    string = Marshal.dump(eb)
    eb2 = Marshal.load(string)
    assert_equal [1,2,3], eb2.v
  end

  class SimpleBox < Eventbox
    sync_call def init(v)
      @v = v
    end
    attr_reader :v
  end

  def test_serialize_box_with_options
    eb = BoxWithOptions.new([1,2,3])

    string = Marshal.dump(eb)
    eb2 = Marshal.load(string)
    assert_equal [1,2,3], eb2.v
    assert_equal 1, eb2.class.eventbox_options[:guard_time]
  end

  class BoxWithOptions < Eventbox.with_options(guard_time: 1)
    sync_call def init(v)
      @v = v
    end
    attr_reader :v
  end

  def test_serialize_fails_with_running_action
    eb = RunningActionBox.new
    err = assert_raises(TypeError) { Marshal.dump(eb) }
    assert_match(/while actions are running/, err.to_s)
    eb.shutdown!
  end

  def test_serialize_succeeds_after_shutdown
    eb = RunningActionBox.new
    eb.shutdown!
    Marshal.dump(eb)
  end

  class RunningActionBox < Eventbox
    public action def init
      sleep
    end
  end
end
