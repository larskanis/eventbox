require_relative "../test_helper"

class EventboxCallTest < Minitest::Test
  def test_call_definition_returns_name
    v = nil
    Class.new(Eventbox) do
      v = async_call def test_async
      end
    end
    assert_equal :test_async, v

    Class.new(Eventbox) do
      v = sync_call def test_sync
      end
    end
    assert_equal :test_sync, v

    Class.new(Eventbox) do
      v = yield_call def test_yield
      end
    end
    assert_equal :test_yield, v
  end

  def test_public_method_error
    err = assert_raises(Eventbox::InvalidAccess) do
      Class.new(Eventbox) do
        def test
        end
      end.new
    end
    assert_match(/method `test' at/, err.to_s)
  end

  def test_initialize_method_error
    err = assert_raises(Eventbox::InvalidAccess) do
      Class.new(Eventbox) do
        def initialize
          super
        end
      end.new
    end
    assert_match(/method `initialize' at/, err.to_s)
  end

  class TestInitWithDef < Eventbox
    async_call def init(num, pr, pi)
      @values = [num.class, pr.class, pi.class, Thread.current.object_id]
    end
    attr_reader :values
    sync_call def thread
      Thread.current.object_id
    end
  end

  def test_init_with_def
    pr = proc {}
    eb = TestInitWithDef.new("123", pr, IO.pipe.first)

    assert_equal String, eb.values[0]
    assert_equal Eventbox::ExternalProc, eb.values[1]
    assert_equal Eventbox::ExternalObject, eb.values[2]
    assert_equal eb.thread, eb.values[3]
  end

  def test_init_with_async_def_and_super
    pr = proc {}
    eb = Class.new(TestInitWithDef) do
      async_call def init(num, pr, pi)
        super
        @values << Thread.current.object_id
      end
    end.new(123, pr, IO.pipe)

    assert_equal eb.thread, eb.values[3], "superclass was called"
    assert_equal eb.thread, eb.values[4], "Methods in derived and superclass are called from the same thread"
  end

  def test_init_with_sync_def_and_super
    pr = proc {}
    eb = Class.new(TestInitWithDef) do
      sync_call def init(num, pr, pi)
        super
        @values << Thread.current.object_id
      end
    end.new(123, pr, IO.pipe)

    assert_equal eb.thread, eb.values[3], "superclass was called"
    assert_equal eb.thread, eb.values[4], "Methods in derived and superclass are called from the same thread"
  end

  def test_init_with_yield_def_and_super
    eb = Class.new(TestInitWithDef) do
      yield_call def init(num, pi, result)
        super
        @values << Thread.current.object_id
        result.yield
      end
    end.new(123, IO.pipe.first)

    assert_equal Eventbox::ExternalObject, eb.values[1], "result is passed to superclass"
    assert_equal eb.thread, eb.values[3], "superclass was called"
    assert_equal eb.thread, eb.values[4], "Methods in derived and superclass are called from the same thread"
  end

  def test_intern_yield_call_fails
    eb = Class.new(Eventbox) do
      sync_call def go
        doit
      rescue => err
        err.to_s
      end

      yield_call def doit(result)
        result.yield
      end
    end.new

    assert_match(/`doit' can not be called internally/, eb.go)
  end

  def test_extern_yield_call_with_multiple_yields
    with_report_on_exception(false) do
      eb = Class.new(Eventbox) do
        yield_call def doit(result)
          result.yield
          result.yield
        end
        sync_call def trigger
          # Make sure the event loop has processed both yields
        end
      end.new

      ex = assert_raises(Eventbox::MultipleResults) { eb.doit; eb.trigger }
      assert_match(/multiple results for method `doit'/, ex.to_s)
    end
  end

  class TestInitWithBlock < Eventbox
    async_call :init do |num, pr, pi|
      @values = [num.class, pr.class, pi.class, Thread.current.object_id]
    end
    attr_reader :values
    sync_call :thread do
      Thread.current.object_id
    end
  end

  def test_init_with_block
    pr = proc {}
    eb = TestInitWithBlock.new("123", pr, IO.pipe.first)

    assert_equal String, eb.values[0]
    assert_equal Eventbox::ExternalProc, eb.values[1]
    assert_equal Eventbox::ExternalObject, eb.values[2]
    assert_equal eb.thread, eb.values[3]
  end

  def test_init_with_async_block_and_super
    pr = proc {}
    eb = Class.new(TestInitWithBlock) do
      async_call :init do |num, pr2, pi2|
        super(num, pr2, pi2) # block form requres explicit parameters
        @values << Thread.current.object_id
      end
    end.new(123, pr, IO.pipe.first)

    assert_equal eb.thread, eb.values[3], "superclass was called"
    assert_equal eb.thread, eb.values[4], "Methods in derived and superclass are called from the same thread"
  end

  def test_async_returns_self
    eb = Class.new(Eventbox) do
      sync_call def syn
        asyn
      end
      async_call def asyn
      end
    end.new

    assert_equal eb, eb.syn, "returns self by internal calls"
    assert_equal eb, eb.asyn, "returns self by external calls"
  end

  def test_external_object_sync_call
    fc = Class.new(Eventbox) do
      sync_call def out(pr)
        [1234, pr, pr.class]
      end
    end.new

    pr = proc{ 543 }
    value = fc.out(pr)

    assert_equal [1234, pr, Eventbox::ExternalProc], value
  end

  def test_external_object_sync_call_tagged
    fc = Class.new(Eventbox) do
      sync_call def out(str)
        [str, str.class.to_s]
      end
    end.new

    str = "abc".dup
    assert_equal "abc", fc.shared_object(str)
    value = fc.out(str)

    assert_equal [str, "Eventbox::ExternalObject"], value
  end

  def test_internal_object_sync_call
    fc = Class.new(Eventbox) do
      sync_call def out
        [1234, proc{ 543 }, async_proc{ 543 }, sync_proc{ 543 }, yield_proc{ 543 }]
      end
    end.new

    assert_equal 1234, fc.out[0]
    assert_kind_of Eventbox::InternalObject, fc.out[1]
    assert_kind_of Eventbox::AsyncProc, fc.out[2]
    assert_kind_of Eventbox::SyncProc, fc.out[3]
    assert_kind_of Eventbox::YieldProc, fc.out[4]
  end

  def test_internal_object_sync_call_tagged
    fc = Class.new(Eventbox) do
      sync_call def out
        shared_object("abc")
      end
    end.new

    assert_kind_of Eventbox::InternalObject, fc.out
  end

  def test_external_proc_called_internally_should_return_nil
    fc = Class.new(Eventbox) do
      sync_call def go(pr, str)
        pr.call(str+"b")
      end
    end.new

    pr = proc { |n| n+"c" }
    assert_nil fc.go(pr, "a")
  end

  def test_external_proc_called_internally_without_completion_block
    fc = Class.new(Eventbox) do
      sync_call def init(pr)
        pr.call(5)
      end
    end

    a = nil
    pr = proc { |n| a = n; }
    fc.new(pr)
    assert_equal 5, a
  end

  def test_external_proc_called_internally_with_sync_block
    fc = Class.new(Eventbox) do
      yield_call def go(pr, str, result)
        pr.call(str+"b", &sync_proc do |r|
          result.yield(r+"d")
        end)
      end
    end.new

    pr = proc { |n, &block| block.yield(n+"c") }
    res = fc.go(pr, "a")
    assert_equal "abcd", res
  end

  def test_external_proc_called_internally_with_plain_block
    fc = Class.new(Eventbox) do
      yield_call def go(pr, result)
        pr.call do
        end
      end
    end.new

    pr = proc { |n, &block|  }
    err = assert_raises(Eventbox::InvalidAccess){ fc.go(pr) }
    assert_match(/with block argument .*#<Proc.* is not allowed/, err.to_s)
  end

  def test_external_proc_called_internally_with_completion_block
    fc = Class.new(Eventbox) do
      yield_call def go(pr, result)
        pr.call(5, proc do |res|
          result.yield res
        end)
      end
    end.new

    pr = proc { |n| n + 1 }
    assert_equal 6, fc.go(pr)
  end

  def test_external_object_invalid_access
    fc = Class.new(Eventbox) do
      sync_call def init(pr)
        pr.call
      end
    end

    with_report_on_exception(false) do
      pr = IO.pipe
      ex = assert_raises(NoMethodError){ fc.new(pr) }
      assert_match(/`call'/, ex.to_s)
    end
  end

  def test_async_proc_called_internally
    fc = Class.new(Eventbox) do
      sync_call def go(str)
        pr = async_proc do |x|
          @n = x+"c"
        end
        [pr.call(str+"b"), @n]
      end
    end.new

    assert_equal [nil, "abc"], fc.go("a")
  end

  def test_async_proc_called_externally
    fc = Class.new(Eventbox) do
      sync_call def pr
        async_proc do |n|
          @n = n + 1
        end
      end
      attr_reader :n
    end.new

    pr = fc.pr
    assert_nil pr.call(123)
    assert_equal 124, fc.n
  end

  def test_async_proc_called_externally_with_block
    fc = Class.new(Eventbox) do
      sync_call def pr
        async_proc do |&block|
          @block = block
        end
      end
      yield_call def n(result)
        @block.call("a", proc { |r| result.yield(r+"c") })
      end
    end.new

    pr = fc.pr
    assert_nil pr.call { |n| n+"b" }
    assert_equal "abc", fc.n
  end

  def test_sync_proc_called_internally
    fc = Class.new(Eventbox) do
      sync_call def go(str)
        pr = sync_proc do |x|
          x+"c"
        end
        pr.call(str+"b")
      end
    end.new

    assert_equal "abc", fc.go("a")
  end

  def test_sync_proc_called_externally
    fc = Class.new(Eventbox) do
      sync_call def pr
        sync_proc do |n|
          n + 1
        end
      end
    end.new

    pr = fc.pr
    assert_equal 124, pr.call(123)
  end

  def test_sync_proc_called_externally_with_block
    fc = Class.new(Eventbox) do
      sync_call def pr
        sync_proc do |n, &block|
          block.call(n+"b", proc { |r| @n = r+"d" })
        end
      end
      attr_reader :n
    end.new

    pr = fc.pr
    assert_nil pr.call("a") { |n| n+"c" }
    assert_equal "abcd", fc.n
  end

  def test_yield_proc_called_internally
    fc = Class.new(Eventbox) do
      sync_call def go
        yield_proc { |result| }.call
      end
    end.new

    err = assert_raises(Eventbox::InvalidAccess){ fc.go }
    assert_match(/can not be called internally/, err.to_s)
  end

  def test_yield_proc_called_externally
    fc = Class.new(Eventbox) do
      sync_call def pr
        yield_proc do |n, result|
          result.yield(n + 1)
        end
      end
    end.new

    pr = fc.pr
    assert_equal 124, pr.call(123)
  end

  def test_yield_proc_called_externally_with_block
    fc = Class.new(Eventbox) do
      sync_call def pr
        yield_proc do |n, result, &block|
          block.call(n+"b", proc { |r| result.yield(r+"d") })
        end
      end
    end.new

    pr = fc.pr
    assert_equal "abcd", pr.call("a") { |n| n+"c" }
  end

  def test_internal_proc_invalid_access
    fc = Class.new(Eventbox) do
      sync_call def pr
        proc{}
      end
    end.new

    pr = fc.pr
    ex = assert_raises(NoMethodError){ pr.call }
    assert_match(/`call'/, ex.to_s)
  end

  class Yielder2 < Eventbox
    yield_call :zero do |res|
      res.yield
    end
    yield_call :one do |num, res|
      res.yield num+1
    end
    yield_call :many do |num, pr, res|
      res.yield num+1, pr
    end
  end

  def test_yield_with_0_1_2_params
    pr = proc { 66 }
    fc = Yielder2.new
    assert_nil fc.zero
    assert_equal 23, fc.one(22)
    assert_equal [45, pr], fc.many(44, pr)
  end

  def test_external_async_call_with_deferred_callback
    fc = Class.new(Eventbox) do
      async_call def go(str, &block)
        @block = block
        @str = str+"b"
      end

      yield_call def call_block(result)
        @block.yield(@str+"c", proc do |cbstr|
          result.yield(cbstr+"e")
        end)
      end
    end.new

    fc.go("a") do |str|
      str + "d"
    end

    assert_equal "abcde", fc.call_block
  end

  def test_external_sync_call_with_deferred_callback
    fc = Class.new(Eventbox) do
      sync_call def go(str, &block)
        @block = block
        @str = str+"b"
      end

      sync_call def call_block(&block)
        @block.yield(@str+"c", proc do |cbstr|
          @str = cbstr+"e"
        end)
        123
      end

      attr_reader :str
    end.new

    fc.go("a") do |str|
      str + "d"
    end

    assert_equal 123, fc.call_block
    assert_equal "abcde", fc.str
  end

  def test_internal_async_call_with_deferred_callback
    fc = Class.new(Eventbox) do
      yield_call def go(str, result)
        with_block(str+"b", result) do |cbstr|
          cbstr+"d"
        end
      end

      async_call def with_block(str, result, &block)
        str = block.yield(str+"c")
        result.yield(str+"e")
      end
    end.new

    res = fc.go("a") do |str|
      str + "d"
    end

    assert_equal "abcde", res
  end

  def test_internal_sync_call_with_deferred_callback
    fc = Class.new(Eventbox) do
      yield_call def go(str, result)
        @call_res = with_block(str+"b", result) do |cbstr|
          cbstr+"d"
        end
      end

      sync_call def with_block(str, result, &block)
        str = block.yield(str+"c")
        result.yield(str+"e")
        str+"f"
      end
      attr_reader :call_res
    end.new

    res = fc.go("a") do |str|
      str + "d"
    end

    assert_equal "abcde", res
    assert_equal "abcdf", fc.call_res
  end

  def test_sync_call_with_callback_recursive
    eb = Class.new(Eventbox) do
      sync_call def callback(str, &block)
        if block
          block.yield(str+"d")
        end
        str+"b"
      end
    end.new

    res2 = res3 = nil
    res1 = eb.callback("a") do |str1|
      res2 = eb.callback(str1+"e") do |str2|
        res3 = eb.callback(str2+"f")
      end
    end

    assert_equal "ab", res1
    assert_equal "adeb", res2
    assert_equal "adedfb", res3
  end

  def test_yield_call_with_callback_recursive
    eb = Class.new(Eventbox) do
      yield_call def callback(str, result, &block)
        if block
          block.yield(str+"d", proc do |str2|
            result.yield str2+"c"
          end)
        else
          result.yield str+"b"
        end
      end
    end.new

    res2 = res3 = nil
    res1 = eb.callback("a") do |str1|
      res2 = eb.callback(str1+"e") do |str2|
        res3 = eb.callback(str2+"f")
      end
    end

    assert_equal "adedfbcc", res1
    assert_equal "adedfbc", res2
    assert_equal "adedfb", res3
  end

  def test_yield_call_with_callback_and_action
    fc = Class.new(Eventbox) do
      yield_call def go(str, result, &block)
        process(str+"b", result, block)
      end

      action def process(str, result, block)
        str = call_back(block, str+"c")
        str = call_back(block, str+"g")
        finish(result, str+"h")
      end

      yield_call def call_back(block, str, result)
        block.yield(str+"d", proc do |cbstr|
          result.yield(cbstr+"f")
        end)
      end

      async_call def finish(result, str)
        result.yield str+"i"
      end
    end.new

    res = fc.go("a") do |str|
      str + "e"
    end
    assert_equal "abcdefgdefhi", res
  end
end
