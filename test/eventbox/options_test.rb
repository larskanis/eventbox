require_relative "../test_helper"

class EventboxOptionsTest < Minitest::Test

  class TestBox < Eventbox
  end

  def test_default_options
    if RUBY_ENGINE=='jruby'
      skip "JRuby might use alternative Thread class."
    else
      assert_equal({threadpool: Thread, guard_time: 0.5, :gc_actions=>false}, Eventbox.eventbox_options)
    end
  end

  def test_with_options
    kl = TestBox.with_options(threadpool: Thread).with_options(www: 1)
    assert_match(/EventboxOptionsTest::TestBox\{.*threadpool.*Thread, .*guard_time.*0.5, .*gc_actions.*false, .*www.*1\}/, kl.inspect)
    assert_equal({threadpool: Thread, guard_time: 0.5, :gc_actions=>false, www: 1}, kl.eventbox_options)
  end

  def test_threadpool_option
    ec = Eventbox.with_options(threadpool: Eventbox::ThreadPool.new(5))
    eb = Class.new(ec) do
      yield_call def init(result)
        @ids = []
        100.times do
          adder(result)
        end
      end

      action def adder(result)
        sleep 0.001
        add(Thread.current.object_id, result)
      end

      async_call def add(id, result)
        @ids << id
        result.yield if @ids.size == 100
      end

      attr_reader :ids
    end.new

    assert_equal 5, eb.ids.uniq.size
    ec.eventbox_options[:threadpool].shutdown!
  end

  FastAndSlow = proc do
    sync_call def fast
    end

    sync_call def slow
      sleep 0.01
    end
  end

  def test_guard_time_nil
    eb = Class.new(Eventbox.with_options(guard_time: nil), &FastAndSlow).new

    assert_output("", ""){ eb.slow }
    assert_output("", ""){ eb.fast }
  end

  def test_guard_time_float
    eb = Class.new(Eventbox.with_options(guard_time: 0.01), &FastAndSlow).new

    assert_output("", /guard time exceeded.*0.01.* in `slow' /){ eb.slow }
    assert_output("", ""){ eb.fast }
  end

  def test_guard_time_proc
    calls = nil
    pr = proc { |*args| calls << args }
    eb = Class.new(Eventbox.with_options(guard_time: pr), &FastAndSlow).new

    calls = []
    assert_output("", ""){ eb.slow }
    assert_equal 1, calls.size
    assert_operator 0.01, :<=, calls[0][0]
    assert_equal :slow, calls[0][1]

    calls = []
    assert_output("", ""){ eb.fast }
    assert_equal 1, calls.size
    assert_operator 0.00, :<=, calls[0][0]
    assert_equal :fast, calls[0][1]
  end

  def test_guard_time_invalid
    assert_raises(ArgumentError) do
      Class.new(Eventbox.with_options(guard_time: :nil), &FastAndSlow).new
    end
  end
end
