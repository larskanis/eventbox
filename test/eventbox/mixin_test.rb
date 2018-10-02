require_relative "../test_helper"

class EventboxMixinTest < Minitest::Test
  module TestMixin
    extend Eventbox::Boxable

    sync_call def s
      321
    end

    async_call def a
      432
    end

    yield_call def y(result)
      result.yield 543
    end

    attr_accessor :attr

    action def yield_value(v, result)
      result.yield v
    end
  end

  def test_mixin_calls
    eb = Class.new(Eventbox) do
      include TestMixin
    end.new
    assert_equal 321, eb.s
    assert_equal eb, eb.a
    assert_equal 543, eb.y
  end

  def test_mixin_attr_accessor
    eb = Class.new(Eventbox) do
      include TestMixin
    end.new
    eb.attr = 5
    assert_equal 5, eb.attr
  end

  def test_mixin_called_internal
    eb = Class.new(Eventbox) do
      include TestMixin

      yield_call def go(result)
        result.yield s
      end
    end.new
    assert_equal 321, eb.go
  end

  def test_mixin_action
    eb = Class.new(Eventbox) do
      include TestMixin

      yield_call def z(v, result)
        yield_value(v, result)
      end
    end.new

    assert_equal 23, eb.z(23)
  end
end
