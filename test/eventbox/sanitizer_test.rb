require_relative "../test_helper"

class EventboxSanitizerTest < Minitest::Test
  def test_untaggable_object_intern
    eb = Class.new(Eventbox) do
      sync_call def go(str)
        shared_object(str)
      end
    end.new

    err = assert_raises(Eventbox::InvalidAccess) { eb.go(eb.shared_object("mutable")) }
    assert_match(/not taggable/, err.to_s)
  end

  def test_shared_object_intern
    eb = Class.new(Eventbox) do
      sync_call def go(obj)
        return obj.class, [shared_object([obj])]
      end
      sync_call def back(obj)
        return obj.class, obj[0].class, obj[0][0].class
      end
    end.new

    kl0, res = eb.go("string")
    assert_equal String, kl0
    assert_equal Array, res.class
    assert_equal Eventbox::WrappedObject, res[0].class

    kl1, kl2, kl3 = eb.back(res)
    assert_equal Array, kl1
    assert_equal Array, kl2
    assert_equal String, kl3
  end

  def test_shared_object_extern
    eb = Class.new(Eventbox) do
      sync_call def go(obj)
        return obj, obj.class, obj[0].class
      end
    end.new

    obj = [eb.shared_object(["string"])]
    res, kl1, kl2 = eb.go(obj)
    assert_equal Array, kl1
    assert_equal Eventbox::ExternalObject, kl2
    assert_same obj[0], res[0]
    assert_equal Array, res.class
    assert_equal Array, res[0].class
    assert_equal "string", res[0][0]
  end

  def test_untaggable_object_extern
    eb = Class.new(Eventbox) do
    end.new

    err = assert_raises(Eventbox::InvalidAccess) { eb.shared_object("mutable".freeze) }
    assert_match(/not taggable/, err.to_s)
    err = assert_raises(Eventbox::InvalidAccess) { eb.shared_object(123) }
    assert_match(/not taggable/, err.to_s)
  end

  def test_internal_object_invalid_access
    fc = Class.new(Eventbox) do
      sync_call def pr
        IO.pipe
      end
    end.new

    ios = fc.pr
    assert_equal Array, ios.class
    io = ios.first
    assert_equal Eventbox::WrappedObject, io.class
    ex = assert_raises(NoMethodError){ ios.first.close }
    assert_match(/[`']close'/, ex.to_s)
  end

  class TestObject
    def initialize(a, b, c)
      @a = a
      @b = b
      @c = c
    end
    attr_reader :a
    attr_reader :b
    attr_reader :c
  end

  def test_dissect_instance_variables
    eb = Class.new(Eventbox) do
      sync_call def go(obj)
        [obj.class, obj.a.class, obj.b.class, obj.c.class]
      end
    end.new

    obj = TestObject.new("abc", proc{}, IO.pipe.first)
    okl, akl, bkl, ckl = eb.go(obj)
    assert_equal TestObject, okl
    assert_equal String, akl
    assert_equal Eventbox::ExternalProc, bkl
    assert_equal Eventbox::ExternalObject, ckl

    assert_equal TestObject, obj.class
    assert_equal String, obj.a.class
    assert_equal Proc, obj.b.class
    assert_equal IO, obj.c.class
  end

  class TestStruct < Struct.new(:a, :b, :c)
    attr_accessor :x
  end

  def test_dissect_struct_members
    eb = Class.new(Eventbox) do
      sync_call def go(obj)
        [obj.class, obj.a.class, obj.b.class, obj.c.class, obj.x.class]
      end
    end.new

    obj = TestStruct.new("abc", proc{}, IO.pipe.first)
    obj.x = "uvw"
    okl, akl, bkl, ckl, xkl = eb.go(obj)
    assert_equal TestStruct, okl
    assert_equal String, akl
    assert_equal Eventbox::ExternalProc, bkl
    assert_equal Eventbox::ExternalObject, ckl
    assert_equal String, xkl

    assert_equal TestStruct, obj.class
    assert_equal String, obj.a.class
    assert_equal Proc, obj.b.class
    assert_equal IO, obj.c.class
    assert_equal String, obj.x.class
  end

  class TestArray < Array
    attr_accessor :x
  end

  def test_dissect_array_values
    eb = Class.new(Eventbox) do
      sync_call def go(obj)
        [obj.class, obj[0].class, obj[1].class, obj[2].class, obj.x.class]
      end
    end.new

    obj = TestArray["abc", proc{}, IO.pipe.first]
    obj.x = "uvw"
    okl, akl, bkl, ckl, xkl = eb.go(obj)
    assert_equal TestArray, okl
    assert_equal String, akl
    assert_equal Eventbox::ExternalProc, bkl
    assert_equal Eventbox::ExternalObject, ckl
    assert_equal String, xkl

    assert_equal TestArray, obj.class
    assert_equal String, obj[0].class
    assert_equal Proc, obj[1].class
    assert_equal IO, obj[2].class
    assert_equal String, obj.x.class
  end

  class TestHash < Hash
    attr_accessor :x
  end

  def test_dissect_hash_values
    eb = Class.new(Eventbox) do
      sync_call def go(obj)
        [obj.class, obj[:a].class, obj[:b].class, obj[:c].class, obj.x.class]
      end
    end.new

    obj = TestHash[a: "abc", b: proc{}, c: IO.pipe.first]
    obj.x = "uvw"
    okl, akl, bkl, ckl, xkl = eb.go(obj)
    assert_equal TestHash, okl
    assert_equal String, akl
    assert_equal Eventbox::ExternalProc, bkl
    assert_equal Eventbox::ExternalObject, ckl
    assert_equal String, xkl

    assert_equal TestHash, obj.class
    assert_equal String, obj[:a].class
    assert_equal Proc, obj[:b].class
    assert_equal IO, obj[:c].class
    assert_equal String, obj.x.class
  end

  def test_dissect_struct_members_fails
    eb = Class.new(Eventbox) do
      sync_call def go(obj)
        [obj.class, obj]
      end
    end.new
    okl, obj = eb.go(Struct.new(:a).new("abc"))
    assert_equal Eventbox::ExternalObject, okl
    assert_equal "abc", obj.a
  end

  class UnmarshalableTestObject < IO
    def initialize(a)
      super(0)
      @a = a
    end
    attr_reader :a
  end

  def test_dissect_instance_variables_fails
    eb = Class.new(Eventbox) do
      sync_call def go(obj)
        [obj.class, obj]
      end
    end.new
    okl, obj = eb.go(UnmarshalableTestObject.new("abc"))
    assert_equal Eventbox::ExternalObject, okl
    assert_equal "abc", obj.a
  end

  class UnmarshalableArray < Array
    def initialize(a)
      super()
      @a = a
    end
    attr_reader :a

    def _dump(v)
      raise TypeError
    end
  end

  def test_dissect_array_values_fails
    eb = Class.new(Eventbox) do
      sync_call def go(obj)
        [obj.class, obj]
      end
    end.new
    okl, obj = eb.go(UnmarshalableArray.new("abc") << "cde")
    assert_equal Eventbox::ExternalObject, okl
    assert_equal "abc", obj.a
    assert_equal ["cde"], obj.to_a
  end

  def test_dissect_hash_values_fails
    eb = Class.new(Eventbox) do
      sync_call def go(obj)
        [obj.class, obj]
      end
    end.new
    okl, obj = eb.go({IO.pipe.first => "abc"})
    assert_equal Eventbox::ExternalObject, okl
    assert_equal ["abc"], obj.values
  end
end
