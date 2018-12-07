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
      v = yield_call def test_yield(result)
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

  def test_yield_method_without_yielder
    assert_raises(ArgumentError) do
      Class.new(Eventbox) do
        yield_call def ytest
        end
      end.new.ytest
    end
  end

  def test_yield_method_with_block_but_without_yielder
    assert_raises(ArgumentError) do
      Class.new(Eventbox) do
        yield_call def ytest(&block)
        end
      end.new.ytest
    end
  end

  def test_initialize_method_error_with_super
    err = assert_raises(Eventbox::InvalidAccess) do
      Class.new(Eventbox) do
        def initialize
          super
        end
      end.new
    end
    assert_match(/method `initialize' at/, err.to_s)
  end

  def test_initialize_method_error_without_super
    err = assert_raises(Eventbox::InvalidAccess) {
      Class.new(Eventbox) do
        def initialize
        end
      end.new
    }
    assert_match(/method `initialize' at/, err.to_s)
  end

  def test_init_call_is_private
    [:async_call, :sync_call, :yield_call].each do |call|
      eb = Class.new(Eventbox) do
        send(call, def init(res=nil)
          res.yield if res
        end)
      end.new

      err = assert_raises(NoMethodError) { eb.init }
      assert_match(/private method `init' called/, err.to_s)
    end
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
    assert_equal Eventbox::WrappedObject, eb.values[2]
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

    assert_equal Eventbox::WrappedObject, eb.values[1], "result is passed to superclass"
    assert_equal eb.thread, eb.values[3], "superclass was called"
    assert_equal eb.thread, eb.values[4], "Methods in derived and superclass are called from the same thread"
  end

  class InternalCall < Eventbox
    yield_call def go(meth, result)
      send(meth, result) do
        123
      end
    end

    async_call def async(result, &block)
      result.yield block.call + 1
    end
    sync_call def sync(result, &block)
      result.yield block.call + 1
    end
    yield_call def yield(result, &block)
      result.yield block.call + 1
    end
  end

  def test_intern_async_call
    assert_equal 124, InternalCall.new.go(:async)
  end
  def test_intern_sync_call
    assert_equal 124, InternalCall.new.go(:sync)
  end
  def test_intern_yield_call
    assert_equal 124, InternalCall.new.go(:yield)
  end

  def test_intern_yield_call_with_multiple_yields
    eb = Class.new(Eventbox) do
      sync_call def init
        y(proc{})
      end
      yield_call def y(result)
        result.yield
        result.yield
      end
    end

    ex = assert_raises(Eventbox::MultipleResults) { eb.new }
    assert_match(/second result yielded for method `y'/, ex.to_s)
  end

  def test_intern_yield_call_without_proc
    eb = Class.new(Eventbox) do
      sync_call def init
        y
      end
      yield_call def y(result)
      end
    end

    ex = assert_raises(Eventbox::InvalidAccess) { eb.new }
    assert_match(/`y' must be called with a Proc object/, ex.to_s)
  end

  def test_intern_yield_call_results_self
    eb = Class.new(Eventbox) do
      sync_call def go
        y( proc { 5 } )
      end

      yield_call def y(result)
        8
      end
    end.new

    assert_equal eb, eb.go
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
      assert_match(/second result yielded for method `doit'/, ex.to_s)
    end
  end

  class TestInitWithBlock < Eventbox
    async_call def init(num, pr, pi)
      @values = [num.class, pr.class, pi.class, Thread.current.object_id]
    end
    attr_reader :values
    sync_call def thread
      Thread.current.object_id
    end
  end

  def test_init_with_block
    pr = proc {}
    eb = TestInitWithBlock.new("123", pr, IO.pipe.first)

    assert_equal String, eb.values[0]
    assert_equal Eventbox::ExternalProc, eb.values[1]
    assert_equal Eventbox::WrappedObject, eb.values[2]
    assert_equal eb.thread, eb.values[3]
  end

  def test_init_with_async_block_and_super
    pr = proc {}
    eb = Class.new(TestInitWithBlock) do
      async_call def init(num, pr2, pi2)
        super(num, pr2, pi2) # block form requires explicit parameters
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

    assert_equal [str, "Eventbox::WrappedObject"], value
  end

  def test_internal_object_sync_call
    fc = Class.new(Eventbox) do
      sync_call def out
        [1234, proc{ 543 }, async_proc{ 543 }, sync_proc{ 543 }, yield_proc{ 543 }]
      end
    end.new

    assert_equal 1234, fc.out[0]
    assert_equal Eventbox::WrappedObject, fc.out[1].class
    assert_equal Eventbox::AsyncProc, fc.out[2].class
    assert_equal Eventbox::SyncProc, fc.out[3].class
    assert_equal Eventbox::YieldProc, fc.out[4].class
  end

  def test_internal_object_sync_call_tagged
    fc = Class.new(Eventbox) do
      sync_call def out
        shared_object("abc".dup)
      end
    end.new

    assert_equal Eventbox::WrappedObject, fc.out.class
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

  def test_external_proc_called_internally_with_external_block
    fc = Class.new(Eventbox) do
      sync_call def go(pr)
        pr.call(pr.class, &pr)
      end
    end.new

    pr = proc do |ext_proc_klass, &block|
      assert_equal Eventbox::ExternalProc, ext_proc_klass
      assert_equal pr, block
    end
    fc.go(pr)
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
      yield_call def go(pr, ext_obj, result)
        pr.call(5, ext_obj, ext_obj.class, IO.pipe[0], proc do |n, ext_obj2|
          result.yield n, ext_obj2, ext_obj2.class, ext_obj, ext_obj.class, IO.pipe[0]
        end)
      end
    end.new

    pr = proc do |n, ext_obj, ext_obj_klass, int_obj|
      assert_equal IO, ext_obj.class
      assert_equal Eventbox::WrappedObject, ext_obj_klass
      assert_equal Eventbox::WrappedObject, int_obj.class
      [n + 1, IO.pipe[0]]
    end

    n, ext_obj2, ext_obj2_klass, ext_obj, ext_obj_klass, int_obj = fc.go(pr, IO.pipe[0])
    assert_equal 6, n
    assert_equal IO, ext_obj2.class
    assert_equal Eventbox::WrappedObject, ext_obj2_klass
    assert_equal IO, ext_obj.class
    assert_equal Eventbox::WrappedObject, ext_obj_klass
    assert_equal Eventbox::WrappedObject, int_obj.class
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
        [pr.call(str+"b") == pr, @n]
      end
    end.new

    assert_equal [true, "abc"], fc.go("a")
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
    assert_same pr, pr.call(123)
    assert_equal 124, fc.n
  end

  def test_async_proc_called_externally_with_completion_block
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
    assert_same pr, pr.call { |n| n+"b" }
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
        sync_proc do |n, ext_obj|
          [n + 1, ext_obj, ext_obj.class, IO.pipe[0]]
        end
      end
    end.new

    pr = fc.pr
    n, ext_obj, ext_obj_klass, int_obj = pr.call(123, IO.pipe[0])
    assert_equal 124, n
    assert_equal IO, ext_obj.class
    assert_equal Eventbox::WrappedObject, ext_obj_klass
    assert_equal Eventbox::WrappedObject, int_obj.class
  end

  def test_async_proc_called_externally_denies_callback
    fc = Class.new(Eventbox) do
      sync_call def pr
        async_proc do |&block|
          block.call
        end
      end
    end.new

    pr = fc.pr
    err = assert_raises(Eventbox::InvalidAccess){ pr.call { } }
    assert_match(/closure was yielded by `Eventbox::AsyncProc'/, err.to_s)
  end

  def test_sync_proc_called_externally_with_completion_block
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
      yield_call def go(gores)
        yield_proc do |result, &block|
          result.yield(block.call + 1)
        end.call(proc do |res|
          gores.yield res
        end) do
          123
        end
      end
    end.new

    assert_equal 124, fc.go
  end

  def test_intern_yield_proc_with_multiple_yields
    eb = Class.new(Eventbox) do
      sync_call def init
        yield_proc do |result|
          result.yield
          result.yield
        end.call(proc{})
      end
    end

    ex = assert_raises(Eventbox::MultipleResults) { eb.new }
    assert_match(/second result yielded for #<Proc:/, ex.to_s)
  end

  def test_intern_yield_proc_without_proc
    eb = Class.new(Eventbox) do
      sync_call def init
        yield_proc do
        end.call
      end
    end

    ex = assert_raises(Eventbox::InvalidAccess) { eb.new }
    assert_match(/#<Proc:.* must be called with a Proc object/, ex.to_s)
  end

  def test_intern_yield_proc_results_nil
    eb = Class.new(Eventbox) do
      sync_call def go
        yield_proc do |result|
          8
        end.call( proc { 5 } )
      end
    end.new

    assert_nil eb.go
  end

  def test_yield_proc_called_externally
    fc = Class.new(Eventbox) do
      sync_call def pr
        yield_proc do |n, ext_obj, result|
          result.yield(n + 1, ext_obj, ext_obj.class, IO.pipe[0])
        end
      end
    end.new

    pr = fc.pr
    n, ext_obj, ext_obj_klass, int_obj = pr.call(123, IO.pipe[0])
    assert_equal 124, n
    assert_equal IO, ext_obj.class
    assert_equal Eventbox::WrappedObject, ext_obj_klass
    assert_equal Eventbox::WrappedObject, int_obj.class
  end

  def test_yield_proc_called_called_two_times
    fc = Class.new(Eventbox) do
      sync_call def pr
        yield_proc do |result|
          result.yield
          result.yield
        end
      end
    end.new

    pr = fc.pr
    err = assert_raises(Eventbox::MultipleResults){ pr.call }
    assert_match(/second result yielded for #<Proc:/, err.to_s)
  end

  def test_yield_proc_called_externally_with_completion_block
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
    yield_call def zero(res)
      res.yield
    end
    yield_call def one(num, res)
      res.yield num+1
    end
    yield_call def many(num, pr, res)
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

  def test_async_call_denies_callback
    fc = Class.new(Eventbox) do
      async_call def init(&block)
        @bl = block
      end
      async_call def go
        @bl.yield
      end
    end.new { }

    err = assert_raises(Eventbox::InvalidAccess){ fc.go }
    assert_match(/closure defined by `init' was yielded by `go'/, err.to_s)
  end

  def test_external_block_called_by_async_call
    eb = Class.new(Eventbox) do
      yield_call def init(result, &block)
        @block = block
        start_response(result)
      end

      action def start_response(result)
        go(result)
      end

      async_call def go(result)
        @block.call("a", proc { result.yield })
      end
    end

    a = []
    eb.new {|v| a << [v, Thread.current] }
    assert_equal [["a", Thread.current]], a
  end

  def test_external_block_called_by_async_proc
    eb = Class.new(Eventbox) do
      yield_call def init(result, &block)
        start_response(async_proc do
          block.call("a", proc do
            result.yield
          end)
        end)
      end

      action def start_response(pr)
        pr.yield
      end
    end

    a = []
    eb.new {|v| a << [v, Thread.current] }
    assert_equal [["a", Thread.current]], a
  end

  def test_external_block_defined_by_yield_proc_and_called_by_async_proc
    eb = Class.new(Eventbox) do
      sync_call def go
        yield_proc do |result, &block|
          start_response(async_proc do
            block.call("a", proc do
              result.yield
            end)
          end)
        end
      end

      action def start_response(pr)
        pr.yield
      end
    end

    a = []
    eb.new.go.call {|v| a << [v, Thread.current] }
    assert_equal [["a", Thread.current]], a
  end

  def test_external_block_called_by_sync_proc
    eb = Class.new(Eventbox) do
      yield_call def init(result, &block)
        start_response(sync_proc do
          block.call("c", proc do
            result.yield
          end)
        end)
      end

      action def start_response(pr)
        pr.yield
      end
    end

    a = []
    eb.new {|v| a << [v, Thread.current] }
    assert_equal 1, a.size
    assert_equal "c", a[0][0]
    refute_equal Thread.current, a[0][1]
  end

  def test_external_block_called_by_async_call_after_return
    ec = Class.new(Eventbox) do
      sync_call def init(&block)
        @block = block
      end

      yield_call def go1(result)
        start_response(result)
      end

      action def start_response(result)
        go2(result)
      end

      async_call def go2(result)
        @block.call("c", proc { result.yield })
      end
    end

    eb = ec.new {}
    with_report_on_exception(false) do
      err = assert_raises(Eventbox::InvalidAccess) { eb.go1 }
      assert_match(/closure defined by `init' was yielded by .* after .* returned/, err.to_s)
    end
  end

  def test_external_block_called_after_yield_result
    eb = Class.new(Eventbox) do
      yield_call def value(result, &block)
        result.yield
        block.call
      end
    end.new

    err = assert_raises(Eventbox::InvalidAccess) { eb.value{} }
    assert_match(/closure can't be called through method `value'/, err.to_s)
  end

  def test_external_block_called_after_raise_result
    eb = Class.new(Eventbox) do
      sync_call def raising_proc
        yield_proc do |result, &block|
          result.raise
          block.call
        end
      end
    end.new

    err = assert_raises(Eventbox::InvalidAccess) { eb.raising_proc.call{} }
    assert_match(/closure can't be called through .*call_test\.rb/, err.to_s)
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

    res = fc.go("a")

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

    res = fc.go("a")

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

  class MyError < RuntimeError
    def initialize(value=nil)
      @value = value
    end
    attr_reader :value
  end

  def test_yield_call_with_raise
    eb = Class.new(Eventbox) do
      yield_call def go(result)
        result.raise MyError.new(IO.pipe[0])
        @num = 123
      end
      attr_reader :num
    end.new

    err = assert_raises(MyError) { eb.go }
    assert_equal Eventbox::WrappedObject, err.value.class
    assert_equal 123, eb.num
  end

  def test_yield_call_with_raise_from_action
    fc = Class.new(Eventbox) do
      yield_call def init(result)
        process(result)
      end

      action def process(result)
        result.raise MyError.new(IO.pipe[0])
      end
    end

    err = assert_raises(MyError) { fc.new }
    assert_equal IO, err.value.class
  end

  def test_yield_proc_with_raise
    eb = Class.new(Eventbox) do
      sync_call def go
        yield_proc do |result|
          result.raise MyError.new(IO.pipe[0])
          @num = 123
        end
      end
      attr_reader :num
    end.new

    pr = eb.go
    err = assert_raises(MyError) { pr.call }
    assert_equal Eventbox::WrappedObject, err.value.class
    assert_equal 123, eb.num
  end

  def test_yield_proc_with_raise_from_action
    fc = Class.new(Eventbox) do
      sync_call def go
        yield_proc do |result|
          process(result)
        end
      end

      action def process(result)
        result.raise MyError.new(IO.pipe[0])
      end
    end

    pr = fc.new.go
    err = assert_raises(MyError) { pr.call }
    assert_equal IO, err.value.class
  end

  def test_yield_call_with_raise_and_yield
    eb = Class.new(Eventbox) do
      yield_call def go(result)
        result.raise MyError
        result.yield 123
      end
    end.new

    assert_raises(Eventbox::MultipleResults) { eb.go }
  end

  def test_inter_eventbox_sync_call_args
    eb1 = Class.new(Eventbox) do
      yield_call def go(eb, ext_obj, result, &ext_proc)
        eb.new(sync_proc{}, "abc", :xyz, IO.pipe[0], result, ext_obj, ext_proc, result) {}
      end
    end
    eb2 = Class.new(Eventbox) do
      sync_call def init(*objs, result, &block)
        result.yield(*objs.map(&:class), block.class)
      end
    end

    objs = eb1.new.go(eb2, IO.pipe[0]) {}
    assert_equal [Eventbox::SyncProc, String, Symbol, Eventbox::WrappedObject, Eventbox::CompletionProc, Eventbox::WrappedObject, Eventbox::ExternalProc, Eventbox::ExternalProc], objs
  end

  def test_inter_eventbox_sync_call_return
    eb1 = Class.new(Eventbox) do
      yield_call def go1(eb, ext_obj, result, &ext_proc)
        rets = eb.new.go2(ext_obj, ext_proc, IO.pipe[0]) {}
        result.yield rets.map(&:class)
      end
    end
    eb2 = Class.new(Eventbox) do
      sync_call def go2(ext_obj, ext_proc, go1_obj, &block)
        return sync_proc{}, "abc", :xyz, IO.pipe[0], ext_obj, ext_proc, go1_obj, block
      end
    end

    objs = eb1.new.go1(eb2, IO.pipe[0]) {}
    assert_equal [Eventbox::SyncProc, String, Symbol, Eventbox::WrappedObject, Eventbox::WrappedObject, Eventbox::ExternalProc, IO, Proc], objs
  end


  [[:sync_call, "check.call(eb.sc(*args))", ":sc"],
   [:sync_proc, "check.call(eb.sp.call(*args))", '"sync_proc'],
   [:async_call, "eb.ac(*args); check.call(eb.async_res)", ":ac"],
   [:async_proc, "eb.ap.call(*args); check.call(eb.async_res)", '"async_proc'],
   [:yield_call, "check.call(eb.yc(*args))", ":yc"],
   [:yield_proc, "check.call(eb.yp.call(*args))", '"yield_proc'],
  ].each do |call_type, code, name|
    ["", "_bl"].each do |bn|
      code2 = bn.empty? ? code : code.gsub(/args\)/, "args){}")
      define_method("test_#{call_type}_wrap_arguments_with_rest#{bn}"){ wrap_arguments_with_rest(call_type, code2, name, bn) }
      define_method("test_#{call_type}_wrap_arguments_without_rest#{bn}"){ wrap_arguments_without_rest(call_type, code2, name, bn) }
    end
    define_method("test_#{call_type}_wrap_with_default_arguments_set"){ wrap_default_arguments_set(call_type, code, name) }
    define_method("test_#{call_type}_wrap_with_default_arguments_unset"){ wrap_default_arguments_unset(call_type, code, name) }
    define_method("test_#{call_type}_wrap_with_keyword_arguments_set"){ wrap_keyword_arguments_set(call_type, code, name) }
    define_method("test_#{call_type}_wrap_with_keyword_arguments_unset"){ wrap_keyword_arguments_unset(call_type, code, name) }
    define_method("test_#{call_type}_wrap_position_and_keyword_arguments"){ wrap_position_and_keyword_arguments(call_type, code, name) }
  end

  # Avoid "warning: assigned but unused variable - eb", etc
  def eval_code(eb, check, args, code)
    eval(code)
  end

  def wrap_arguments_with_rest(call_type, code, name, bl)
    eb = WrapArguments.new
    args = [:o1, :o2, :rest1, :rest2, :o3, :o4]
    check = proc do |res|
      assert_equal 7, res.size
      assert_equal Symbol, res[0]
      assert_equal Eventbox::WrappedObject, res[1]
      assert_equal Eventbox::WrappedObject, res[2]
      assert_equal Eventbox::WrappedObject, res[3]
      assert_equal Symbol, res[4]
      assert_equal Eventbox::WrappedObject, res[5]
      if bl.empty?
        assert_equal NilClass, res[6]
      else
        assert_equal Eventbox::ExternalProc, res[6]
      end
    end
    eval_code(eb, check, args, code)
  end

  def wrap_arguments_without_rest(call_type, code, name, bl)
    eb = WrapArguments.new
    args = [:o1, :o2, :o3, :o4]
    check = proc do |res|
      assert_equal 5, res.size
      assert_equal Symbol, res[0]
      assert_equal Eventbox::WrappedObject, res[1]
      assert_equal Symbol, res[2]
      assert_equal Eventbox::WrappedObject, res[3]
      if bl.empty?
        assert_equal NilClass, res[4]
      else
        assert_equal Eventbox::ExternalProc, res[4]
      end
    end
    eval_code(eb, check, args, code)
  end

  class WrapArguments < Eventbox
    sync_call def sc(o1, €o2, *€rest, o3, €o4, &ext_proc)
      return o1.class, €o2.class, *€rest.map(&:class), o3.class, €o4.class, ext_proc.class
    end
    sync_call def sp
      sync_proc do |o1, €o2, *€rest, o3, €o4, &ext_proc|
        [o1.class, €o2.class, *€rest.map(&:class), o3.class, €o4.class, ext_proc.class]
      end
    end
    async_call def ac(o1, €o2, *€rest, o3, €o4, &ext_proc)
      @async_res = [o1.class, €o2.class, *€rest.map(&:class), o3.class, €o4.class, ext_proc.class]
    end
    sync_call def ap
      async_proc do |o1, €o2, *€rest, o3, €o4, &ext_proc|
        @async_res = [o1.class, €o2.class, *€rest.map(&:class), o3.class, €o4.class, ext_proc.class]
      end
    end
    attr_reader :async_res
    yield_call def yc(o1, €o2, *€rest, o3, €o4, result, &ext_proc)
      result.yield o1.class, €o2.class, *€rest.map(&:class), o3.class, €o4.class, ext_proc.class
    end
    sync_call def yp
      yield_proc do |o1, €o2, *€rest, o3, €o4, result, &ext_proc|
        result.yield o1.class, €o2.class, *€rest.map(&:class), o3.class, €o4.class, ext_proc.class
      end
    end
  end

  def wrap_default_arguments_set(call_type, code, name)
    eb = WrapDefaultArguments.new
    args = [:O1, :O2, :rest1, :rest2, :O3]
    check = proc do |res|
      assert_equal 8, res.size
      assert_equal Symbol, res[0]
      assert_equal ":O1", res[1]
      assert_equal Eventbox::WrappedObject, res[2]
      assert_match(/@object=:O2 @name=:€b/, res[3])
      assert_equal Symbol, res[4]
      assert_equal Symbol, res[5]
      assert_equal Eventbox::WrappedObject, res[6]
      assert_match(/@object=:O3 @name=:€c/, res[7])
    end
    eval_code(eb, check, args, code)
  end

  def wrap_default_arguments_unset(call_type, code, name)
    eb = WrapDefaultArguments.new
    args = [:O3]
    check = proc do |res|
      assert_equal 6, res.size
      assert_equal Symbol, res[0]
      assert_equal ":A", res[1]
      assert_equal Symbol, res[2]
      assert_equal ":B", res[3]
      assert_equal Eventbox::WrappedObject, res[4]
      assert_match(/@object=:O3 @name=:€c/, res[5])
    end
    eval_code(eb, check, args, code)
  end

  class WrapDefaultArguments < Eventbox
    sync_call def sc(a=:A, €b=:B, *rest, €c)
      return a.class, a.inspect, €b.class, €b.inspect, *rest.map(&:class), €c.class, €c.inspect
    end
    sync_call def sp
      sync_proc do |a=:A, €b=:B, *rest, €c|
        [a.class, a.inspect, €b.class, €b.inspect, *rest.map(&:class), €c.class, €c.inspect]
      end
    end
    async_call def ac(a=:A, €b=:B, *rest, €c)
      @async_res = [a.class, a.inspect, €b.class, €b.inspect, *rest.map(&:class), €c.class, €c.inspect]
    end
    sync_call def ap
      async_proc do |a=:A, €b=:B, *rest, €c|
        @async_res = [a.class, a.inspect, €b.class, €b.inspect, *rest.map(&:class), €c.class, €c.inspect]
      end
    end
    attr_reader :async_res
    yield_call def yc(a=:A, €b=:B, *rest, €c, result)
      result.yield a.class, a.inspect, €b.class, €b.inspect, *rest.map(&:class), €c.class, €c.inspect
    end
    sync_call def yp
      yield_proc do |a=:A, €b=:B, *rest, €c, result|
        result.yield a.class, a.inspect, €b.class, €b.inspect, *rest.map(&:class), €c.class, €c.inspect
      end
    end
  end

  def wrap_keyword_arguments_set(call_type, code, name)
    eb = WrapKeywordArguments.new
    args = [€a: :A, b: :B, €c: :C, d: :D, g: :G, h: :H]
    check = proc do |res|
      assert_equal 10, res.size
      assert_equal Eventbox::WrappedObject, res[0]
      assert_match(/@object=:A @name=:€a/, res[1])
      assert_equal Symbol, res[2]
      assert_equal ":B", res[3]
      assert_equal Eventbox::WrappedObject, res[4]
      assert_match(/@object=:C @name=:€c/, res[5])
      assert_equal Symbol, res[6]
      assert_equal ":D", res[7]
      assert_equal [:g, Eventbox::WrappedObject], res[8]
      assert_equal [:h, Eventbox::WrappedObject], res[9]
    end
    eval_code(eb, check, args, code)
  end

  def wrap_keyword_arguments_unset(call_type, code, name)
    eb = WrapKeywordArguments.new
    args = [€a: :A1, d: :D1]
    check = proc do |res|
      assert_equal 8, res.size
      assert_equal Eventbox::WrappedObject, res[0]
      assert_match(/@object=:A1 @name=:€a/, res[1])
      assert_equal Symbol, res[2]
      assert_equal ":b", res[3]
      assert_equal Symbol, res[4]
      assert_equal ":c", res[5]
      assert_equal Symbol, res[6]
      assert_equal ":D1", res[7]
    end
    eval_code(eb, check, args, code)
  end

  class WrapKeywordArguments < Eventbox
    sync_call def sc(€a:, b: :b, €c: :c, d:, **€krest)
      return *[€a, b, €c, d].flat_map { |v| [v.class, v.inspect] }, *€krest.map{|k,v| [k, v.class] }
    end
    sync_call def sp
      sync_proc do |€a:, b: :b, €c: :c, d:, **€krest|
        [*[€a, b, €c, d].flat_map { |v| [v.class, v.inspect] }, *€krest.map{|k,v| [k, v.class] }]
      end
    end
    async_call def ac(€a:, b: :b, €c: :c, d:, **€krest)
      @async_res = [*[€a, b, €c, d].flat_map { |v| [v.class, v.inspect] }, *€krest.map{|k,v| [k, v.class] }]
    end
    sync_call def ap
      async_proc do |€a:, b: :b, €c: :c, d:, **€krest|
        @async_res = [*[€a, b, €c, d].flat_map { |v| [v.class, v.inspect] }, *€krest.map{|k,v| [k, v.class] }]
      end
    end
    attr_reader :async_res
    yield_call def yc(result, €a:, b: :b, €c: :c, d:, **€krest)
      result.yield(*[€a, b, €c, d].flat_map { |v| [v.class, v.inspect] }, *€krest.map{|k,v| [k, v.class] })
    end
    sync_call def yp
      yield_proc do |result, €a:, b: :b, €c: :c, d:, **€krest|
        result.yield(*[€a, b, €c, d].flat_map { |v| [v.class, v.inspect] }, *€krest.map{|k,v| [k, v.class] })
      end
    end
  end

  def wrap_position_and_keyword_arguments(call_type, code, name)
    eb = WrapPositionalAndKeywordArguments.new
    args = [:A, :B, g: :G, h: :H]
    check = proc do |res|
      assert_equal 6, res.size
      assert_equal Eventbox::WrappedObject, res[0]
      assert_match(/@object=:A @name=:€a/, res[1])
      assert_equal Symbol, res[2]
      assert_equal ":B", res[3]
      assert_equal [:g, Symbol], res[4]
      assert_equal [:h, Symbol], res[5]
    end
    eval_code(eb, check, args, code)
  end

  class WrapPositionalAndKeywordArguments < Eventbox
    sync_call def sc(€a, b, **krest)
      return *[€a, b].flat_map { |v| [v.class, v.inspect] }, *krest.map{|k,v| [k, v.class] }
    end
    sync_call def sp
      sync_proc do |€a, b, **krest|
        [*[€a, b].flat_map { |v| [v.class, v.inspect] }, *krest.map{|k,v| [k, v.class] }]
      end
    end
    async_call def ac(€a, b, **krest)
      @async_res = [*[€a, b].flat_map { |v| [v.class, v.inspect] }, *krest.map{|k,v| [k, v.class] }]
    end
    sync_call def ap
      async_proc do |€a, b, **krest|
        @async_res = [*[€a, b].flat_map { |v| [v.class, v.inspect] }, *krest.map{|k,v| [k, v.class] }]
      end
    end
    attr_reader :async_res
    yield_call def yc(€a, b, result, **krest)
      result.yield(*[€a, b].flat_map { |v| [v.class, v.inspect] }, *krest.map{|k,v| [k, v.class] })
    end
    sync_call def yp
      yield_proc do |€a, b, result, **krest|
        result.yield(*[€a, b].flat_map { |v| [v.class, v.inspect] }, *krest.map{|k,v| [k, v.class] })
      end
    end
  end
end
