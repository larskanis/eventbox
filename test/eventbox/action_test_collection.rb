# These tests are executed twice: with and without threadpool.

class FcSleep < Eventbox
  yield_call def wait(time, result)
    sleeper(time, result)
  end

  action def sleeper(time, result)
    sleep(time)
    timeout(result)
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
    modify_action(@str, result)
    @str << "e"
  end

  action def modify_action(str, result)
    modify(str, result)
    str << "c"
  end

  private def after_events
    @str << "b"
  end

  async_call def modify(str, result)
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
    create_pipe
  end

  action def create_pipe
    pipeios_opened(*IO.pipe)
  end

  async_call def pipeios_opened(inp, out)
    @inp = inp
    @out = out
    pipe_active
  end

  private def pipe_active
    read_pipe(@inp)
    write_pipe(@out)
  end

  action def read_pipe inp
    received(inp.read(1))
  end

  action def write_pipe out
    out.write "A"
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

def test_action_with_internal_object_call
  fc = Class.new(Eventbox) do
    yield_call def go(result)
      pr = proc{ 321 }
      send_out("111", pr, result)
    end

    action def send_out(num, pr, result)
      finish num, num.class.to_s, pr, pr.class.to_s, result
    end

    async_call def finish(num, num_class, pr, pr_class, result)
      result.yield num, num_class, pr, pr_class
    end
  end.new

  values = fc.go
  assert_equal "111", values[0]
  assert_equal "String", values[1]
  assert_equal Eventbox::WrappedObject, values[2].class
  assert_equal "Eventbox::WrappedObject", values[3]
end

def test_action_external_object_tagged
  str = "mutable".dup
  fc = Class.new(Eventbox) do
    yield_call def go(str, result)
      send_out(str, result)
    end

    action def send_out(str, result)
      finish str.class, str, result
    end

    async_call def finish(str_class, str, result)
      result.yield str_class, str
    end
  end.new

  klass, str2 = fc.go(fc.shared_object(str))

  assert_equal String, klass
  assert_same str, str2
end

class Yielder1 < Eventbox
  yield_call def delayed(pr, i, ths, bl)
    @bl = bl
    ths << Thread.current.object_id
    finish(pr, i+1, ths)
  end

  action def finish pr, i, ths
    ths << Thread.current.object_id
    finished(pr, i+1, ths)
  end

  async_call def finished(pr, i, ths)
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
      act(result)
    end

    action def act(res2)
      res1 = await_res1
      res1.yield(1)
      res2.yield(2)
    end

  end.new

  th1 = Thread.new { fc.a }
  th2 = Thread.new { fc.b }
  assert_equal 1, th1.value
  assert_equal 2, th2.value
end

def test_action_overwrites_local_variables
  fc = Class.new(Eventbox) do
    attr_accessor :outside_block
    yield_call def local_var(result)
      a_local_variable = "local var"
      exiter(result)
      sleep 0.001
      # the local variable shouldn't change, even after the action thread started
      self.outside_block = a_local_variable
    end

    action def exiter(result)
      # the local variable should be overwritten within the block
      return_res result, begin
        a_local_variable
      rescue Exception => err
        err.to_s
      end
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
      exiter(a, result)

      sleep 0.001
      # the local variable shouldn't change, even after the action thread started
      a << " outside block"
      self.outside_block = a
    end

    action def exiter a, result
      # the local variable should be overwritten within the block
      a << " inside block"
      return_res a, result
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
      exiter(result)
    end
    action def exiter(result)
      result.yield instance_variable_defined?("@a")
    end
  end.new
  assert_equal false, fc.inst_var
end

def test_action_access_to_private_methods_doesnt_leak_instance_variables
  eb = Class.new(Eventbox) do
    yield_call def go(result)
      @var1 = 123
      exiter(result)
    end
    action def exiter(result)
      @var2 = 321
      result.yield private_meth
    end
    private def private_meth
      [@var1, @var2]
    end
  end.new
  res = silence_warnings { eb.go }
  assert_equal [nil, 321], res
end

class TestActionRaise < Eventbox
  class Stop < Interrupt
    def initialize(result, value)
      @result = result
      @value = value
    end
    attr_reader :result
    attr_reader :value
  end

  async_call def init
    @a = sleepy
  end

  action def sleepy
    Thread.handle_interrupt(Stop => :on_blocking) do
      sleep
    end
  rescue Stop => err
    err.result.yield(err, err.value.class)
  end

  yield_call def stop(result)
    @a.raise Stop.new(result, IO.pipe[0])
  end

  attr_reader :a
end

def test_action_raise
  eb = TestActionRaise.new
  assert_equal Eventbox::Action, eb.a.class
  assert_equal :sleepy, eb.a.name
  err, err_klass = eb.stop
  assert_equal TestActionRaise::Stop, err.class
  assert_equal Eventbox::WrappedObject, err_klass
end

def test_action_abort_in_init
  eb = Class.new(Eventbox) do
    yield_call def init(str, result)
      a = sleepy(str+"b", result)
      a.abort
    end

    action def sleepy(str, result)
      str << "c"
      sleep
    ensure
      self.str = str+"d"
      result.yield
    end

    attr_accessor :str
  end.new("a")

  assert_equal "abcd", eb.str
end

def test_action_abort_in_init_with_action_param
  eb = Class.new(Eventbox) do
    yield_call def init(str, result)
      @str = str+"b"
      sleepy(result)
    end

    action def sleepy(result, ac)
      stop_myself(ac)
      sleep
    ensure
      self.str += "d"
      result.yield
    end

    async_call def stop_myself(ac)
      @str << "c"
      ac.abort
    end

    attr_accessor :str
  end.new("a")

  assert_equal "abcd", eb.str
end

def test_action_abort_by_raise_is_denied
  eb = Class.new(Eventbox) do
    sync_call def go
      a = sleepy
      a.raise(Eventbox::AbortAction)
    end

    sync_call def go2
      a = sleepy
      a.raise(Eventbox::AbortAction.new("dummy"))
    end

    action def sleepy
    end
  end.new

  err = assert_raises(Eventbox::InvalidAccess){ eb.go }
  assert_match(/AbortAction is not allowed/, err.to_s)
  err = assert_raises(Eventbox::InvalidAccess){ eb.go2 }
  assert_match(/AbortAction is not allowed/, err.to_s)
end

def test_action_current_p
  eb = Class.new(Eventbox) do
    yield_call def outside(result)
      a = sleepy
      result.yield a.current?
      a.abort
    end

    action def sleepy
      sleep
    end

    yield_call def inside(result)
      retu(result)
    end

    action def retu(result, a)
      result.yield a.current?
    end
  end.new

  refute eb.outside
  assert eb.inside
end

def test_action_can_call_methods_from_base_class
  ec = Class.new(Eventbox) do
    attr_reader :str
  end
  eb = Class.new(ec) do
    yield_call def go(result)
      @str = "a"
      action_thread(result)
    end
    action def action_thread(result)
      result.yield str
    end
  end.new

  assert_equal "a", eb.go
end

def test_action_can_call_methods_from_sub_class
  ec = Class.new(Eventbox) do
    yield_call def go(result)
      @str = "a"
      action_thread(result)
    end
    action def action_thread(result)
      result.yield str
    end
  end
  eb = Class.new(ec) do
    attr_reader :str
  end.new

  assert_equal "a", eb.go
end

def test_action_call_in_action
  eb = Class.new(Eventbox) do
    yield_call def go(str, result)
      action1(str+"b", result)
    end
    action def action1(str, result)
      action2(str+"c", result)
    end
    action def action2(str, result)
      result.yield str+"d"
    end
  end.new

  assert_equal "abcd", eb.go("a")
end

class TestInitWithPendingAction < Eventbox
  yield_call def init(result)
    suspended_thread(result)
  end

  action def suspended_thread(result)
    wait_forever(result)
  end

  yield_call def wait_forever(init_result, result)
    init_result.yield
    # Call never returns to the action, when not yielding result
    # until GC destroys the Eventbox instance
    #    result.yield
  end

  async_call def shutdown_nonblocking
    shutdown!
  end

  yield_call def shutdown_blocking(result)
    shutdown! do
      result.yield
    end
  end
end

def test_several_instances_running_actions_dont_interfere
  ec = Class.new(Eventbox) do
    yield_call def init(result)
      @count = 0
      10.times do
        adder(result)
      end
    end

    async_call def add(result)
      result.yield if (@count+=1) == 10
    end

    action def adder(result)
      sleep 0.001
      add(result)
    end
  end

  10.times.map do
    Thread.new do
      ec.new
    end
  end.each(&:join)
end

def test_shutdown_external
  eb = TestInitWithPendingAction.new
  eb.shutdown!
  eb.shutdown!
end

def test_shutdown_internal_nonblocking
  eb = TestInitWithPendingAction.new
  eb.shutdown_nonblocking
  eb.shutdown_nonblocking
end

def test_shutdown_internal_blocking
  eb = TestInitWithPendingAction.new
  eb.shutdown_blocking
  eb.shutdown_blocking
end

def test_call_definition_returns_name
  v = nil
  Class.new(Eventbox) do
    v = action def test_action
    end
  end
  assert_equal :test_action, v
end

def test_action_call_is_private
  eb = Class.new(Eventbox) do
    action def a
    end
  end.new

  err = assert_raises(NoMethodError) { eb.a }
  assert_match(/private method [`']a' called/, err.to_s)
end

def test_sync_proc_in_action
  eb = Class.new(Eventbox) do
    yield_call def go(sym, result)
      ac(sym, result)
    end
    public action def ac(sym, result)
      send(sym) {}
    rescue => err
      result.raise err
    end
  end.new

  err = assert_raises(Eventbox::InvalidAccess) { eb.go(:async_proc) }
  assert_match(/async_proc outside of the event scope is not allowed/, err.to_s)
  err = assert_raises(Eventbox::InvalidAccess) { eb.go(:sync_proc) }
  assert_match(/sync_proc outside of the event scope is not allowed/, err.to_s)
  err = assert_raises(Eventbox::InvalidAccess) { eb.go(:yield_proc) }
  assert_match(/yield_proc outside of the event scope is not allowed/, err.to_s)
end

def test_new_action_call_context_on_external_object
  eb = Class.new(Eventbox) do
    yield_call def go(€obj, result)
      ctx = new_action_call_context
      €obj.send(ctx, :concat, "a")
      €obj.send(ctx, :concat, "b", proc{|res| result.yield ctx.class, res })
    end
  end.new

  assert_equal [Eventbox::ActionCallContext, "ab"], eb.go("".dup)
end

def test_new_action_call_context_on_external_proc
  eb = Class.new(Eventbox) do
    yield_call def go(result, &block)
      ctx = new_action_call_context
      block.call(ctx, "a")
      block.call(ctx, "b", proc{|res| result.yield ctx.class, res })
    end
  end.new

  strs = []
  ths = []
  ctx, res = eb.go do |str|
    strs << str
    ths << Thread.current
    5
  end

  assert_equal Eventbox::ActionCallContext, ctx
  assert_equal 5, res
  assert_equal %w[ a b ], strs
  refute_equal Thread.current, ths[0]
  refute_equal Thread.current, ths[1]
  assert_equal ths[0], ths[1]
end

def test_async_call_with_call_context
  eb = Class.new(Eventbox) do
    async_call def go(€obj)
      ctx = new_action_call_context
      with_call_context(ctx) do
        €obj.send :enq, ctx.class
      end
    end
  end.new

  q = Queue.new
  eb.go(q)
  assert_equal Eventbox::ActionCallContext, q.deq
end

def test_yield_call_with_call_context
  eb = Class.new(Eventbox) do
    yield_call def go(€obj, result)
      ctx = new_action_call_context
      with_call_context(ctx) do
        €obj.send(:current, -> (€th) { result.yield €th })
      end
    end
  end.new

  res = eb.go(Thread)
  assert_equal Thread, res.class
  refute_equal Thread.current, res
end


# Not working - just an idea:
#
# def test_call_chain
#   eb = Class.new(Eventbox) do
#     yield_call def go(€obj, result)
#       ctx = new_action_call_context
#       ctx[€obj, :concat, "a"].then do |€res|
#         [€res, :concat, "b"]
#       end.then do |€res|
#         [€res, :concat, "c"]
#       end.then do |€res|
#         result.yield ctx.class, €res
#       end
#     end
#   end.new
#
#   assert_equal [Eventbox::ActionCallContext, "abc"], eb.go("".dup)
# end
