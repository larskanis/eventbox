require_relative "../test_helper"

class EventboxArgumentSanitizerTest < Minitest::Test
  def test_untaggable_object_intern
    eb = Class.new(Eventbox) do
      sync_call def go(str)
        mutable_object(str)
      end
    end.new

    err = assert_raises(Eventbox::InvalidAccess) { eb.go(eb.mutable_object("mutable")) }
    assert_match(/not taggable/, err.to_s)
  end

  def test_untaggable_object_extern
    eb = Class.new(Eventbox) do
    end.new

    err = assert_raises(Eventbox::InvalidAccess) { eb.mutable_object("mutable".freeze) }
    assert_match(/not taggable/, err.to_s)
    err = assert_raises(Eventbox::InvalidAccess) { eb.mutable_object(123) }
    assert_match(/not taggable/, err.to_s)
  end

  def test_internal_object_invalid_access
    fc = Class.new(Eventbox) do
      sync_call def pr
        IO.pipe
      end
    end.new

    pr = fc.pr
    ex = assert_raises(NoMethodError){ pr.call }
    assert_match(/`call'/, ex.to_s)
  end
end
