require_relative "../test_helper"

class EventboxCallContextTest < Minitest::Test
  def test_action_class
    eb = Class.new(Eventbox) do
      sync_call def go
        ctx = new_action_call_context.action
        ctx.class
      end
    end.new
    assert_equal Eventbox::Action, eb.go
  end

  def test_action_current_false
    eb = Class.new(Eventbox) do
      sync_call def go
        ac = new_action_call_context.action
        ac.current?
      end
    end.new
    assert_equal false, eb.go
    eb.shutdown!
  end

  def test_action_current_true
    eb = Class.new(Eventbox) do
      yield_call def go(result)
        ctx = new_action_call_context
        €(ctx.action).send(ctx, :current?, result)
      end
    end.new
    assert_equal true, eb.go
  end

  def test_action_abort_and_join
    eb = Class.new(Eventbox) do
      yield_call def go(result)
        ac = new_action_call_context.action
        €(ac).send(:abort)
        €(ac).send(:join, result)
      end
    end.new
    eb.go
  end
end
