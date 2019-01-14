require_relative "../test_helper"

class ExamplesConcurrentWorkersTest < Minitest::Test
  class ConcurrentWorkers < Eventbox
    async_call def init
      @tasks = []
      @waiting = {}
      @working = {}
    end

    async_call def add_worker(workerid)
      worker(workerid)
    end

    action def worker(workerid)
      while n=next_task(workerid)
        task_finished(workerid, "#{n} finished")
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
    cw.shutdown!
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

    yield_call def process(name, result)
      @tasks << [result, name]
      check_work
    end

    private yield_call def next_task(workerid, input)
      @waiting[workerid] = input
      check_work
    end
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
    cw.shutdown!
  end

  class ConcurrentWorkersWithCallback < ConcurrentWorkers2
    async_call def init
      super
      @notify_when_finished = []
    end

    async_call def process(name, &block)
      @tasks << [block, name]
      check_work
    end

    sync_call def task_finished(workerid, result)
      @working.delete(workerid).yield result
      if @tasks.empty? && @working.empty?
        @notify_when_finished.each(&:yield)
      end
    end

    yield_call def finish_tasks(result)
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
    cw.shutdown!
  end
end
