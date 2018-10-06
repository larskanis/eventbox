# These tests are executed twice: with and without threadpool.

class FcSleep < Eventbox
  yield_call def wait(time, result)
    sleeper(time, result)
  end

  action :sleeper do |time, result|
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
    if @inp
      read_pipe(@inp)
    end

    if @out
      write_pipe(@out)
    end
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
  assert_kind_of Eventbox::InternalObject, values[2]
  assert_equal "Eventbox::InternalObject", values[3]
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

  klass, str2 = fc.go(fc.mutable_object(str))

  assert_equal String, klass
  assert_same str, str2
end

class Yielder1 < Eventbox
  yield_call :delayed do |pr, i, ths, bl|
    @bl = bl
    ths << Thread.current.object_id
    finish(pr, i+1, ths)
  end

  action def finish pr, i, ths
    ths << Thread.current.object_id
    finished(pr, i+1, ths)
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

def test_action_from_wrong_thread
  eb = Class.new(Eventbox) do
    sync_call def init
      @error = Thread.new do
        begin
          dummy
        rescue => err
          err.inspect
        end
      end.value
    end

    action def dummy
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
      return_res(result, instance_variable_defined?("@a"))
    end
    async_call def return_res(result, var)
      result.yield var
    end
  end.new
  assert_equal false, fc.inst_var
end

class TestActionRaise < Eventbox
  class Stop < Interrupt
    def initialize(result)
      @result = result
    end
    attr_reader :result
  end

  async_call def init
    @a = sleepy
  end

  action def sleepy
    Thread.handle_interrupt(Stop => :on_blocking) do
      sleep
    end
  rescue Stop => err
    err.result.yield(err)
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

def test_action_abort_in_init
  eb = Class.new(Eventbox) do
    yield_call def init(str, result)
      @str = str+"b"
      a = sleepy(@str, result)
      a.abort
      result.yield
    end

    action def sleepy(str, result)
      str << "c"
      sleep
    ensure
      self.str = str+"d"
    end

    attr_accessor :str
  end.new("a")

  assert_operator(["ab", "abcd"], :include?, eb.str)
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
end

def test_100_init_with_pending_action
  100.times do
    TestInitWithPendingAction.new
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
