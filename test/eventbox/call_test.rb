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
    assert_match(/multiple results for method `y'/, ex.to_s)
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
    assert_equal Eventbox::WrappedObject, eb.values[2]
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

    assert_equal [str, "Eventbox::WrappedObject"], value
  end

  def test_internal_object_sync_call
    fc = Class.new(Eventbox) do
      sync_call def out
        [1234, proc{ 543 }, async_proc{ 543 }, sync_proc{ 543 }, yield_proc{ 543 }]
      end
    end.new

    assert_equal 1234, fc.out[0]
    assert_kind_of Eventbox::WrappedObject, fc.out[1]
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

    assert_kind_of Eventbox::WrappedObject, fc.out
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
        pr.call(5, ext_obj, ext_obj.class, IO.pipe[0], proc do |res|
          result.yield res, ext_obj, ext_obj.class, IO.pipe[0]
        end)
      end
    end.new

    pr = proc do |n, ext_obj, ext_obj_klass, int_obj|
      assert_kind_of IO, ext_obj
      assert_equal Eventbox::WrappedObject, ext_obj_klass
      assert_kind_of Eventbox::WrappedObject, int_obj
      [n + 1, IO.pipe[0]]
    end

    n, ext_obj, ext_obj_klass, int_obj = fc.go(pr, IO.pipe[0])
    assert_equal 6, n
    assert_kind_of IO, ext_obj
    assert_equal Eventbox::WrappedObject, ext_obj_klass
    assert_kind_of Eventbox::WrappedObject, int_obj
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
    assert_kind_of IO, ext_obj
    assert_equal Eventbox::WrappedObject, ext_obj_klass
    assert_kind_of Eventbox::WrappedObject, int_obj
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
    assert_match(/multiple results for #<Proc:/, ex.to_s)
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
    assert_kind_of IO, ext_obj
    assert_equal Eventbox::WrappedObject, ext_obj_klass
    assert_kind_of Eventbox::WrappedObject, int_obj
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
    assert_match(/received multiple results for #<Proc:/, err.to_s)
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
    assert_kind_of Eventbox::WrappedObject, err.value
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
    assert_kind_of IO, err.value
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
    assert_kind_of Eventbox::WrappedObject, err.value
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
    assert_kind_of IO, err.value
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
        eb.new(sync_proc{}, "abc", 123, IO.pipe[0], result, ext_obj, ext_proc, result) {}
      end
    end
    eb2 = Class.new(Eventbox) do
      sync_call def init(*objs, result, &block)
        result.yield(*objs.map(&:class), block.class)
      end
    end

    objs = eb1.new.go(eb2, IO.pipe[0]) {}
    assert_equal [Eventbox::SyncProc, String, Integer, Eventbox::WrappedObject, Eventbox::CompletionProc, Eventbox::WrappedObject, Eventbox::ExternalProc, Eventbox::ExternalProc], objs
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
        return sync_proc{}, "abc", 123, IO.pipe[0], ext_obj, ext_proc, go1_obj, block
      end
    end

    objs = eb1.new.go1(eb2, IO.pipe[0]) {}
    assert_equal [Eventbox::SyncProc, String, Integer, Eventbox::WrappedObject, Eventbox::WrappedObject, Eventbox::ExternalProc, IO, Proc], objs
  end
end
