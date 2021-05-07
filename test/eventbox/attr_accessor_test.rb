require_relative "../test_helper"

class EventboxAttrAccessorTest < Minitest::Test
  def test_attr_accessor
    fc = Class.new(Eventbox) do
      sync_call def init
        @percent = 0
      end
      attr_accessor :percent
    end.new

    fc.percent = 10
    assert_equal 10, fc.percent
    fc.percent = "20"
    assert_equal "20", fc.percent
  end

  def test_attr_writer
    fc = Class.new(Eventbox) do
      sync_call def get
        @percent
      end
      attr_writer :percent
    end.new

    fc.percent = 10
    assert_equal 10, fc.get
    assert_raises(NoMethodError) { fc.percent }
  end

  def test_attr_reader
    fc = Class.new(Eventbox) do
      async_call def init
        @percent = 10
      end
      attr_reader :percent
    end.new

    assert_equal 10, fc.percent
    assert_raises(NoMethodError) { fc.percent = 3 }
  end

  def test_attr_accessor2
    fc = Class.new(Eventbox) do
      sync_call def init
        @percent = 0
        @percent2 = IO.pipe[0]
      end
      attr_accessor :percent, :percent2
    end.new

    assert_instance_of Eventbox::WrappedObject, fc.percent2
    fc.percent2 = 10
    assert_equal 10, fc.percent2
    assert_equal 0, fc.percent
    fc.percent = "20"
    assert_equal "20", fc.percent
  end

  def test_attr_writer2
    fc = Class.new(Eventbox) do
      sync_call def get
        @percent
      end
      sync_call def get2
        @percent2.class
      end
      attr_writer :percent, :percent2
    end.new

    fc.percent = 10
    assert_equal 10, fc.get
    fc.percent2 = IO.pipe[0]
    assert_equal Eventbox::ExternalObject, fc.get2
  end

  def test_attr_reader2
    fc = Class.new(Eventbox) do
      async_call def init
        @percent = 10
        @percent2 = IO.pipe[0]
      end
      attr_reader :percent, :percent2
    end.new

    assert_equal 10, fc.percent
    assert_instance_of Eventbox::WrappedObject, fc.percent2
  end
end
