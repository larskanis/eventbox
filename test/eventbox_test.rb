require_relative "test_helper"

class EventboxTest < Minitest::Test
  def test_that_it_has_a_version_number
    assert_match(/\A\d+\.\d+\.\d+/, ::Eventbox::VERSION)
  end

  def setup
    @start_threads = Thread.list
  end

  def teardown
    sleep 0.1 if (Thread.list - @start_threads).any?
    lingering = Thread.list - @start_threads
    if lingering.any?
      puts "#{lingering.length} lingering threads:"
      lingering.each do |th|
        puts "    #{th.backtrace&.find{|t| !(t=~/\/eventbox\.rb:/) } }"
      end
    end

    # Trigger ObjectRegistry#untag
    GC.start
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

  class FcSleep < Eventbox
    private def start
      action 0.01 do |o|
        def o.o time
          sleep(time)
          timeout
        end
      end
    end

    async_call def timeout
      exit_run
    end
  end

  def test_sleep
    st = Time.now
    FcSleep.new.run
    assert_operator Time.now-st, :>=, 0.01
  end

  class FcModifyParams < Eventbox
    private def start
      @str = "a".dup
      action @str, def modify_action str
        modify(str)
        str << "c"
      end
    end

    private def repeat
      @str << "b"
    end

    async_call :modify do |str|
      exit_run str
      str << "d"
    end
  end

  def test_modify_params
    str = FcModifyParams.new.run
    assert_equal "ad", str
  end

  class FcExtToIntObject < Eventbox
    private def start
      @inp = nil
      @out = nil
      action def create_pipe
        pipeios(*IO.pipe)
      end
    end

    private def repeat
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

    private def stop
      @final_char = @char
    end

    async_call :pipeios do |inp, out|
      @inp = inp
      @out = out
    end

    async_call :received do |char|
      @char = char
      exit_run
    end

    sync_call :final_char do
      @final_char
    end
  end

  def test_ExtToIntObject
    fc = FcExtToIntObject.new
    fc.run
    assert_equal "A", fc.final_char
  end

  def test_ext_to_int_sync_call_with_result
    fc = Class.new(Eventbox) do
      sync_call def out(pr)
        exit_run
        [1234, Thread.current.object_id, pr, pr.class]
      end
    end.new

    pr = proc{ 543 }
    th = Thread.new do
      fc.out(pr)
    end
    fc.run

    assert_equal [1234, Thread.current.object_id, pr, Eventbox::ExternalObject], th.value
  end

  def test_int_to_ext_call
    pr = proc{234}
    fc = Class.new(Eventbox) do
      async_call def go(pr)
        action pr, def send_out(pr)
          exit_run pr.class, pr
        end
      end
    end.new

    fc.go(pr)
    assert_equal [Eventbox::InternalObject, pr], fc.run
  end

  def test_int_to_ext_tagged
    str = "mutable".dup
    fc = Class.new(Eventbox) do
      async_call def go(str)
        str << " in go"
        action str, def send_out(str)
          exit_run str.class, str
        end
      end
    end.new

    fc.go(fc.mo(str))
    klass, str2 = fc.run

    assert_equal Eventbox::InternalObject, klass
    assert_same str, str2
  end

  def test_untaggable_object
    fc = Class.new(Eventbox) do
      private def start
        str = mo("mutable")
        action str, def tag(str)
          mo(str)
          exit_run
        rescue => err
          exit_run err.to_s
        end
      end
    end.new
    assert_match(/not taggable/, fc.run)
  end

  def test_ext_to_int_tagged
    fc = Class.new(Eventbox) do
      private def start
        action def send_in
          str = mo("mutable".dup)
          input str.object_id, str
        end
      end

      async_call def input(ob1, str)
        kl = str.class
        action ob1, kl, str, def send_out(ob1, kl, str)
          exit_run ob1, kl, str.object_id, str
        end
      end
    end.new

    ob1, kl, ob2, str = fc.run

    assert_equal Eventbox::ExternalObject, kl
    assert_equal ob1, ob2
    assert_kind_of Eventbox::ExternalObject, str
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
      exit_run
      ths << Thread.current.object_id
      @bl.yield [pr, i+1, ths]
      false
    end
  end

  def test_yield_call_through_action
    fc = Yielder1.new
    pr = proc{ 543 }
    th = Thread.new do
      fc.delayed(pr, 1, [Thread.current.object_id])
    end
    fc.run

    assert_equal [pr, 4], th.value[0, 2]
    refute_equal Thread.current.object_id, th.value[-1][0]
    assert_equal Thread.current.object_id, th.value[-1][1]
    refute_equal Thread.current.object_id, th.value[-1][2]
    assert_equal Thread.current.object_id, th.value[-1][3]
    refute_equal th.value[-1][0], th.value[-1][2]
    assert_equal 543, th.value[0].call
  end

  class Yielder2 < Eventbox
    yield_call def many(pr, num, bl)
      bl.yield pr, num+1, Thread.current.object_id
      false
    end
    yield_call def one(num, bl)
      bl.yield num+1
      false
    end
    yield_call def zero(bl)
      bl.yield
      false
    end
  end

  def test_yield_call_same_thread
    fc = Yielder2.new
    pr = proc{ 543 }

    assert_nil fc.zero
    assert_equal 44, fc.one(43)
    assert_equal [pr, 1235, Thread.current.object_id], fc.many(pr, 1234)
  end

  def test_yield_call_other_thread
    pr = proc{ 543 }

    fc = Yielder2.new
    Thread.new do
      fc.exit_run(fc.zero)
    end
    assert_nil fc.run

    fc = Yielder2.new
    Thread.new do
      fc.exit_run(fc.one 77)
    end
    assert_equal 78, fc.run

    fc = Yielder2.new
    Thread.new do
      fc.exit_run(*fc.many(pr, 88))
    end
    assert_kind_of Eventbox::ExternalObject, fc.run[0]
    assert_equal 89, fc.run[1]
  end

  def test_yield_call_same_thread_no_result
    fc = Class.new(Eventbox) do
      yield_call :out do |_result|
      end
    end.new

    assert_raises( Eventbox::NoResult ) { fc.out }
  end

  def test_mutable_invalid_access_at_async_call
    fc = Class.new(Eventbox) do
      private def start
        action def run_test
          test(proc{})
        end
      end

      async_call :test do |mut|
        mut.object # raises InvalidAccess
      end
    end.new

    ex = assert_raises(Eventbox::InvalidAccess){ fc.run }
    assert_match(/access to .* not allowed/, ex.to_s)
  end

  def test_attr_accessor
    fc = Class.new(Eventbox) do
      private def repeat
        exit_run if @percent==100
      end
      attr_accessor :percent
    end.new

    th = Thread.new do
      fc.percent = 10
      a = fc.percent
      fc.percent = 100
      a
    end
    fc.run

    assert_equal 100, fc.percent
    assert_equal 10, th.value
  end

  class ExitRun1 < Eventbox
    async_call :zero do
      exit_run
    end
    async_call :one do |num|
      exit_run num+1
    end
    async_call :many do |num, pr|
      exit_run num+1, pr
    end
  end

  def test_exit_run_same_thread
    fc = ExitRun1.new
    fc.zero
    assert_nil fc.run

    fc = ExitRun1.new
    fc.one 22
    assert_equal 23, fc.run

    pr = proc { 66 }
    fc = ExitRun1.new
    fc.many 44, pr
    assert_equal [45, pr], fc.run
  end

  def test_exit_run_other_thread
    fc = ExitRun1.new
    Thread.new { fc.zero }
    assert_nil fc.run

    fc = ExitRun1.new
    Thread.new { fc.one 22 }
    assert_equal 23, fc.run

    pr = proc { 77 }
    fc = ExitRun1.new
    Thread.new { fc.many 44, pr }
    assert_equal 45, fc.run[0]
    assert_kind_of Eventbox::ExternalObject, fc.run[1]
  end

  def test_run_from_wrong_thread
    fc = Thread.new do
      Class.new(Eventbox).new
    end.value

    ex = assert_raises(Eventbox::InvalidAccess){ fc.run }
    assert_match(/run must be called from the same thread as new/, ex.to_s)
  end

  def test_action_from_wrong_thread
    with_report_on_exception(false) do
      fc = Class.new(Eventbox) do
        private def start
          Thread.new do
            action def dummy
            end
          end
        end
      end.new

      ex = assert_raises(Eventbox::InvalidAccess){ fc.run }
      assert_match(/action must be called from the same thread as new/, ex.to_s)
    end
  end

  def test_overwrites_local_variables
    fc = Class.new(Eventbox) do
      attr_accessor :outside_block
      private def start
        a_local_variable = "local var"
        action def exiter
          # the local variable should be overwritten within the block
          exit_run begin
            a_local_variable
          rescue Exception => err
            err.to_s
          end
        end
        sleep 0.001
        # the local variable shouldn't change, even after the action thread started
        self.outside_block = a_local_variable
      end
    end.new

    assert_match(/undefined.*a_local_variable/, fc.run)
    assert_equal "local var", fc.outside_block
  end

  def test_passing_local_variables
    fc = Class.new(Eventbox) do
      attr_accessor :outside_block
      private def start
        a = "local var".dup
        action a, def exiter a
          # the local variable should be overwritten within the block
          a << " inside block"
          exit_run a
        end

        sleep 0.001
        # the local variable shouldn't change, even after the action thread started
        a << " outside block"
        self.outside_block = a
      end
    end.new

    assert_equal "local var inside block", fc.run
    assert_equal "local var outside block", fc.outside_block
  end

  def test_denies_access_to_instance_variables
    fc = Class.new(Eventbox) do
      private def start
        @a = "instance var"
        action def exiter
          exit_run instance_variable_defined?("@a")
        end
      end
    end.new
    assert_equal false, fc.run
  end

  def test_public_method_error
    err = assert_raises(Eventbox::InvalidAccess) do
      Class.new(Eventbox) do
        def test
        end
        private def start
          exit_run
        end
      end.new
    end
    assert_match(/method `test' at/, err.to_s)
  end

  def test_action_method_name_error
    fc = Class.new(Eventbox) do
      private def start
        action def run
          exit_run
        end
      end
    end.new
    err = assert_raises(Eventbox::InvalidAccess) { fc.run }
    assert_match(/action method name `run' at/, err.to_s)
  end

  class ConcurrentWorkers < Eventbox
    def initialize(*args)
      super
      @tasks = []
      @waiting = {}
      @working = {}
      @tasks_running = 0
      @results = {}
    end

    async_call def add_worker(workerid)
      action workerid, def worker(workerid)
        while n=next_task(workerid)
          task_finished(workerid, "#{n} finished")
        end
      end
    end

    async_call def add_task(taskid)
      @tasks_running += 1
      action taskid, def task(taskid)
        res = process("task #{taskid}")
        add_to_result_list(taskid, res)
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

    yield_call def next_task(workerid, input)
      if @tasks.empty?
        @waiting[workerid] = input
      else
        result, name = @tasks.shift
        input.yield name
        @working[workerid] = result
      end
    end

    async_call def task_finished(workerid, result)
      @working.delete(workerid).yield result
    end

    async_call def add_to_result_list(taskid, res)
      @results[taskid] = res
      @tasks_running -= 1
      exit_run @results if @tasks_running == 0
    end
  end

  class ConcurrentWorkers2 < ConcurrentWorkers
    private def repeat
      while @tasks.any? && @waiting.any?
        workerid, input = @waiting.shift
        result, name = @tasks.shift
        input.yield name
        @working[workerid] = result
      end
    end

    yield_call :process do |name, result|
      @tasks << [result, name]
    end

    yield_call :next_task do |workerid, input|
      @waiting[workerid] = input
    end
  end

  def test_concurrent_workers
    cw = ConcurrentWorkers.new
    10.times do |workerid|
      cw.add_task(workerid)
    end
    2.times do |workerid|
      cw.add_worker(workerid)
    end

    assert_equal 10.times.each.with_object({}){|i, h| h[i] = "task #{i} finished" }, cw.run
  end

  def test_concurrent_workers2
    cw = ConcurrentWorkers2.new
    cw.add_worker(0)

    th = Thread.new do
      values = 10.times.map do |taskid|
        Thread.new do
          cw.add_worker(taskid) if taskid > 5
          cw.process("task #{taskid}")
        end
      end.map(&:value)
      cw.exit_run

      values
    end
    cw.run

    assert_equal 10.times.map{|i| "task #{i} finished" }, th.value
  end

  def test_yield_call_with_callback_same_thread
    fc = Class.new(Eventbox) do
      yield_call def go(str, result, &block)
        str = call_back(block, str+"b")
        str = call_back(block, str+"f")
        finish(result, str+"g")
      end

      yield_call def call_back(block, str, result)
        block.yield(str+"c") do |cbstr|
          result.yield(cbstr+"e")
        end
      end

      async_call def finish(result, str)
       result.yield str+"h"
      end
    end.new

    res = fc.go("a") do |str|
      str + "d"
    end
    assert_equal "abcdefcdegh", res
  end

  def test_yield_call_with_callback_other_thread
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

    Thread.new do
      res = fc.go("a") do |str|
        str + "e"
      end
      fc.exit_run res
    end
    assert_equal "abcdefgdefhi", fc.run
  end
end
