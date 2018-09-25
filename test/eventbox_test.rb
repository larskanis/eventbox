require_relative "test_helper"

class EventboxTest < Minitest::Test
  include Minitest::Hooks

  def test_that_it_has_a_version_number
    assert_match(/\A\d+\.\d+\.\d+/, ::Eventbox::VERSION)
  end

  def before_all
    @start_threads = Thread.list
  end

  def after_all
    # Trigger ObjectRegistry#untag and thread stopping
    GC.start
    sleep 0.1 if (Thread.list - @start_threads).any?

    lingering = Thread.list - @start_threads
    if lingering.any?
      warn "Warning: #{lingering.length} lingering threads"
      lingering.each do |th|
        line = th.backtrace&.find{|t| t=~/test\// } or
            th.backtrace&.find{|t| !(t=~/lib\/eventbox(\/|\.rb:)/) } or
            th.backtrace&.first
        warn "    #{ line }"
      end
    end
  end

  def with_report_on_exception(enabled)
    if Thread.respond_to?(:report_on_exception)
      old = Thread.report_on_exception
      Thread.report_on_exception = enabled
      begin
        yield
      ensure
        Thread.report_on_exception = old
      end
    else
      yield
    end
  end

  class TestInitWithPendingAction < Eventbox
    yield_call def init(result)
      action result, def suspended_thread(result)
        wait_forever(result)
      end
    end

    yield_call def wait_forever(init_result, result)
      init_result.yield
      # Call never returns to the action, when not yielding result
      # until GC destroys the Eventbox instance
      #    result.yield
    end
  end

  def _test_100_init_with_pending_action
    100.times do
      TestInitWithPendingAction.new
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
    eb = TestInitWithDef.new("123", pr, IO.pipe)

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
    end.new(123, IO.pipe)

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
    eb = TestInitWithBlock.new("123", pr, IO.pipe)

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
    end.new(123, pr, IO.pipe)

    assert_equal eb.thread, eb.values[3], "superclass was called"
    assert_equal eb.thread, eb.values[4], "Methods in derived and superclass are called from the same thread"
  end

  class FcSleep < Eventbox
    yield_call def wait(time, result)
      action time, result do |o|
        def o.o time, result
          sleep(time)
          timeout(result)
        end
      end
    end

    async_call def timeout(result)
      result.yield
    end
  end

  def test_sleep
    st = Time.now
    FcSleep.new.wait(0.01)
    assert_operator Time.now-st, :>=, 0.01
  end

  class FcModifyParams < Eventbox
    yield_call def go(str, result)
      @str = str
      action @str, result, def modify_action(str, result)
        modify(str, result)
        str << "c"
      end
      @str << "e"
    end

    private def after_events
      @str << "b"
    end

    async_call :modify do |str, result|
      str << "d"
      result.yield str
    end
  end

  def test_modify_params
    str = "a"
    eb = FcModifyParams.new(str)
    assert_equal "ad", eb.go(str)
    assert_equal "a", str
  end

  class FcPipe < Eventbox
    async_call def init
      @inp = nil
      @out = nil
      @char = nil
      @result = nil
      action def create_pipe
        pipeios_opened(*IO.pipe)
      end
    end

    async_call def pipeios_opened(inp, out)
      @inp = inp
      @out = out
      pipe_active
    end

    private def pipe_active
      if @inp
        action @inp, def read_pipe inp
          received(inp.read(1))
        end
      end

      if @out
        action @out, def write_pipe out
          out.write "A"
        end
      end
    end

    async_call def received(char)
      @char = char
      if @result
        @result.yield char
        @result = nil
      end
    end

    yield_call def await_char(result)
      if @char
        result.yield @char
      else
        @result = result
      end
    end
  end

  def test_pipe
    fc = FcPipe.new
    assert_equal "A", fc.await_char
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
    assert_equal "abc", fc.mutable_object(str)
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
        mutable_object("abc")
      end
    end.new

    assert_kind_of Eventbox::InternalObject, fc.out
  end

  def test_action_with_internal_object_call
    fc = Class.new(Eventbox) do
      yield_call def go(result)
        pr = proc{ 321 }
        action "111", pr, result, def send_out(num, pr, result)
          finish num, num.class.to_s, pr, pr.class.to_s, result
        end
      end

      async_call def finish(num, num_class, pr, pr_class, result)
        result.yield num, num_class, pr, pr_class
      end
    end.new

    values = fc.go
    assert_equal "111", values[0]
    assert_equal "String", values[1]
    assert_kind_of Eventbox::InternalObject, values[2]
    assert_equal "Eventbox::InternalObject", values[3]
  end

  def test_action_external_object_tagged
    str = "mutable".dup
    fc = Class.new(Eventbox) do
      yield_call def go(str, result)
        action str, result, def send_out(str, result)
          finish str.class, str, result
        end
      end

      async_call def finish(str_class, str, result)
        result.yield str_class, str
      end
    end.new

    klass, str2 = fc.go(fc.mutable_object(str))

    assert_equal String, klass
    assert_same str, str2
  end

  def test_untaggable_object
    eb = Class.new(Eventbox) do
      sync_call def go(str)
        mutable_object(str)
      end
    end.new

    err = assert_raises(Eventbox::InvalidAccess) { eb.go(eb.mutable_object("mutable")) }
    assert_match(/not taggable/, err.to_s)
  end

  def test_untaggable_object
    eb = Class.new(Eventbox) do
    end.new

    err = assert_raises(Eventbox::InvalidAccess) { eb.mutable_object("mutable".freeze) }
    assert_match(/not taggable/, err.to_s)
  end

  class Yielder1 < Eventbox
    yield_call :delayed do |pr, i, ths, bl|
      @bl = bl
      ths << Thread.current.object_id
      action pr, i+1, ths, def finish pr, i, ths
        ths << Thread.current.object_id
        finished(pr, i+1, ths)
      end
    end

    async_call :finished do |pr, i, ths|
      ths << Thread.current.object_id
      @bl.yield [pr, i+1, ths]
      false
    end
  end

  def test_yield_call_through_action
    fc = Yielder1.new
    pr = proc{ 543 }
    values = fc.delayed(pr, 1, [Thread.current.object_id])

    assert_equal [pr, 4], values[0, 2]
    assert_equal Thread.current.object_id, values[-1][0]
    refute_equal Thread.current.object_id, values[-1][2]
    refute_equal Thread.current.object_id, values[-1][3]
    assert_equal 543, values[0].call
  end

  def test_external_proc_called_internally_without_block
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

  def test_external_proc_called_internally_with_block
    fc = Class.new(Eventbox) do
      yield_call def go(pr, result)
        pr.call(5) do |res|
          result.yield res
        end
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
    pr.call(123)
    assert_equal 124, fc.n
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

  def test_results_yielded_in_action
    fc = Class.new(Eventbox) do
      async_call def init
        @res1 = nil
        @waiting = nil
      end

      yield_call def a(result)
        @res1 = result
        @waiting.yield(result) if @waiting
      end

      yield_call def await_res1(res1_isthere)
        if @res1
          res1_isthere.yield(@res1)
        else
          @waiting = res1_isthere
        end
      end

      yield_call def b(result)
        action result, def act(res2)
          res1 = await_res1
          res1.yield(1)
          res2.yield(2)
        end
      end
    end.new

    th1 = Thread.new { fc.a }
    th2 = Thread.new { fc.b }
    assert_equal 1, th1.value
    assert_equal 2, th2.value
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

  def test_action_from_wrong_thread
    eb = Class.new(Eventbox) do
      sync_call def init
        @error = Thread.new do
          begin
            action def dummy
            end
          rescue => err
            err.inspect
          end
        end.value
      end
      attr_reader :error
    end.new

    assert_match(/Eventbox::InvalidAccess/, eb.error)
    assert_match(/action must be called from/, eb.error)
  end

  def test_action_overwrites_local_variables
    fc = Class.new(Eventbox) do
      attr_accessor :outside_block
      yield_call def local_var(result)
        a_local_variable = "local var"
        action result, def exiter(result)
          # the local variable should be overwritten within the block
          return_res result, begin
            a_local_variable
          rescue Exception => err
            err.to_s
          end
        end
        sleep 0.001
        # the local variable shouldn't change, even after the action thread started
        self.outside_block = a_local_variable
      end

      async_call def return_res(result, var)
        result.yield var
      end
    end.new

    assert_match(/undefined.*a_local_variable/, fc.local_var)
    assert_equal "local var", fc.outside_block
  end

  def test_action_passing_local_variables
    fc = Class.new(Eventbox) do
      attr_accessor :outside_block
      yield_call def local_var(result)
        a = "local var".dup
        action a, result, def exiter a, result
          # the local variable should be overwritten within the block
          a << " inside block"
          return_res a, result
        end

        sleep 0.001
        # the local variable shouldn't change, even after the action thread started
        a << " outside block"
        self.outside_block = a
      end

      async_call def return_res(var, result)
        result.yield var
      end
    end.new

    assert_equal "local var inside block", fc.local_var
    assert_equal "local var outside block", fc.outside_block
  end

  def test_action_denies_access_to_instance_variables
    fc = Class.new(Eventbox) do
      yield_call def inst_var(result)
        @a = "instance var"
        action result, def exiter(result)
          return_res(result, instance_variable_defined?("@a"))
        end
      end
      async_call def return_res(result, var)
        result.yield var
      end
    end.new
    assert_equal false, fc.inst_var
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

  def test_action_method_name_error
    with_report_on_exception(false) do
      err = assert_raises(Eventbox::InvalidAccess) do
        Class.new(Eventbox) do
          sync_call def init
            action def init
            end
          end
        end.new
      end
      assert_match(/action method name `init' at/, err.to_s)
    end
  end

  class ConcurrentWorkers < Eventbox
    async_call def init
      @tasks = []
      @waiting = {}
      @working = {}
    end

    async_call def add_worker(workerid)
      action workerid, def worker(workerid)
        while n=next_task(workerid)
          task_finished(workerid, "#{n} finished")
        end
      end
    end

    yield_call def process(name, result)
      if @waiting.empty?
        @tasks << [result, name]
      else
        workerid, input = @waiting.shift
        input.yield name
        @working[workerid] = result
      end
    end

    private yield_call def next_task(workerid, input)
      if @tasks.empty?
        @waiting[workerid] = input
      else
        result, name = @tasks.shift
        input.yield name
        @working[workerid] = result
      end
    end

    private async_call def task_finished(workerid, result)
      @working.delete(workerid).yield result
    end
  end

  def test_concurrent_workers
    cw = ConcurrentWorkers.new

    values = 10.times.map do |taskid|
      Thread.new do
        cw.add_worker(taskid) if taskid > 5
        cw.process "task #{taskid}"
      end
    end.map(&:value)

    assert_equal 10.times.map { |i| "task #{i} finished" }, values
  end

  class ConcurrentWorkers2 < ConcurrentWorkers
    private def check_work
      while @tasks.any? && @waiting.any?
        workerid, input = @waiting.shift
        result, name = @tasks.shift
        input.yield name
        @working[workerid] = result
      end
    end

    yield_call :process do |name, result|
      @tasks << [result, name]
      check_work
    end

    private(yield_call(:next_task) do |workerid, input|
      @waiting[workerid] = input
      check_work
    end)
  end

  def test_concurrent_workers2
    cw = ConcurrentWorkers2.new
    cw.add_worker(0)

    values = 10.times.map do |taskid|
      Thread.new do
        cw.add_worker(taskid) if taskid > 5
        cw.process("task #{taskid}")
      end
    end.map(&:value)

    assert_equal 10.times.map{|i| "task #{i} finished" }, values
  end

  class ConcurrentWorkersWithCallback < ConcurrentWorkers2
    async_call def init
      super
      @notify_when_finished = []
    end

    async_call :process do |name, &block|
      @tasks << [block, name]
      check_work
    end

    sync_call :task_finished do |workerid, result|
      @working.delete(workerid).yield result
      if @tasks.empty? && @working.empty?
        @notify_when_finished.each(&:yield)
      end
    end

    yield_call :finish_tasks do |result|
      if @tasks.empty? && @working.empty?
        result.yield
      else
        @notify_when_finished << result
      end
    end
  end

  def test_concurrent_workers_with_callback
    cw = ConcurrentWorkersWithCallback.new
    cw.add_worker(0)

    values = Queue.new
    10.times do |taskid|
      cw.add_worker(taskid) if taskid > 5
      cw.process("task #{taskid}") do |result|
        values << [taskid, result]
      end
    end
    cw.finish_tasks # should yield block to process

    assert_equal 10.times.map{|i| [i, "task #{i} finished"] }, 10.times.map{ values.deq }.sort
  end

  def test_external_async_call_with_deferred_callback
    fc = Class.new(Eventbox) do
      async_call def go(str, &block)
        @block = block
        @str = str+"b"
      end

      yield_call def call_block(result)
        @block.yield(@str+"c") do |cbstr|
          result.yield(cbstr+"e")
        end
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
        @block.yield(@str+"c") do |cbstr|
          @str = cbstr+"e"
        end
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

  def test_yield_call_with_callback_and_action
    fc = Class.new(Eventbox) do
      yield_call def go(str, result, &block)
        action str+"b", result, block, def process(str, result, block)
          str = call_back(block, str+"c")
          str = call_back(block, str+"g")
          finish(result, str+"h")
        end
      end

      yield_call def call_back(block, str, result)
        block.yield(str+"d") do |cbstr|
          result.yield(cbstr+"f")
        end
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

  class TestQueue < Eventbox
    async_call def init
      @que = []
      @waiting = []
    end

    async_call def enq(value)
      @que << value
      if w=@waiting.shift
        w.yield @que.shift
      end
    end

    yield_call def deq(result)
      if @que.empty?
        @waiting << result
      else
        result.yield @que.shift
      end
    end
  end

  def test_queue
    q = TestQueue.new

    # Start two threads which enqueues values
    2.times do |s|
      Thread.new do
        500.times do |i|
          q.enq(2 * i + s)
        end
        q.enq nil
      end
    end

    # Start two thread which fetch values concurrently
    l1, l2 = 2.times.map do
      Thread.new do
        l = []
        while v=q.deq
          l << v
        end
        l
      end
    end.map(&:value)

    assert_operator 1..999, :===, l1.size
    assert_operator 1..999, :===, l2.size
    assert_equal 1000.times.to_a, (l1 + l2).sort
  end

  class TestThreadPool < Eventbox
    async_call def init(pool_size)
      @que = []
      @jobless = []

      pool_size.times do
        action def pool_thread
          while bl=next_job
            bl.yield
          end
        end
      end
    end

    protected yield_call def next_job(result)
      if @que.empty?
        @jobless << result
      else
        result.yield @que.shift
      end
    end

    async_call def pool(&block)
      if @jobless.empty?
        @que << block
      else
        @jobless.shift.yield block
      end
    end
  end

  def test_thread_pool
    tp = TestThreadPool.new(3)

    q = TestQueue.new
    50.times do |i|
      tp.pool do
        sleep 0.001
        q.enq [i, Thread.current.object_id]
      end
    end

    results = 50.times.map { q.deq }
    assert_equal 50.times.to_a, results.map(&:first).sort
    assert_equal 3, results.map(&:last).uniq.size
  end

  def test_shutdown
    GC.start    # Try to sweep other pending threads
    sleep 0.01

    c1 = Thread.list.length
    eb = TestInitWithPendingAction.new
    c2 = Thread.list.length
    assert_equal c1+1, c2, "There should be a new thread"

    eb.shutdown!

    sleep 0.01
    c3 = Thread.list.length
    assert_equal c1, c3, "The new thread should be removed"
  end

  class TestActionRaise < Eventbox
    class Stop < AbortAction
      def initialize(result)
        @result = result
      end
      attr_reader :result
    end

    async_call def init
      @a = action def sleepy
        sleep
      rescue Stop => err
        err.result.yield(err)
      end
    end

    yield_call def stop(result)
      @a.raise(Stop, result)
    end

    attr_reader :a
  end

  def test_action_raise
    eb = TestActionRaise.new
    assert_kind_of Eventbox::Action, eb.a
    assert_equal :sleepy, eb.a.name
    assert_kind_of TestActionRaise::Stop, eb.stop
  end

  def test_action_raise_abort_in_init
    eb = Class.new(Eventbox) do
      yield_call def init(str, result)
        a = action str+"b", result, def sleepy(str, result)
          str << "c"
          sleep
        ensure
          self.str = str+"d"
          result.yield
        end

        a.raise(Eventbox::AbortAction)
      end

      attr_accessor :str
    end.new("a")

    assert_equal "abcd", eb.str
  end
end
