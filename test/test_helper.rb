require 'simplecov'
SimpleCov.start


BEGIN {
  @start_threads = Thread.list
}

END {
  # Trigger ObjectRegistry#untag and thread stopping
  GC.start
  sleep 0.1 if (Thread.list - @start_threads).any?

  lingering = Thread.list - @start_threads
  if lingering.any?
    warn "Warning: #{lingering.length} lingering threads"
    lingering.each do |th|
      line = th.backtrace&.find{|t| t=~/test\// } ||
          th.backtrace&.find{|t| !(t=~/lib\/eventbox(\/|\.rb:)/) } ||
          th.backtrace&.first
      warn "    #{ line }"
    end
    # puts lingering.last.backtrace
  end
}

$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "eventbox"
require "minitest/autorun"
require 'minitest/hooks/test'

Thread.abort_on_exception = true

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

def silence_warnings
  original_verbosity = $VERBOSE
  $VERBOSE = nil
  res = yield
  $VERBOSE = original_verbosity
  res
end

def eval_file(local_file)
  fn = File.expand_path(local_file, __dir__)
  class_eval(File.read(fn, encoding: "UTF-8"), fn)
end

def with_fake_time
  time = Time.at(0)

  time_now = proc do
    time
  end

  kernel_sleep = proc do |sec=nil|
    if sec
      time += sec
      sleep 0.001
    else
      sleep 10
      raise "sleep not interrupted"
    end
  end

  Time.stub(:now, time_now) do
    Kernel.stub(:sleep, kernel_sleep) do
      yield
    end
  end
end

def assert_elapsed_time(seconds, delta=0.01)
  st = Time.now
  yield
  dt = Time.now - st
  assert_in_delta seconds, dt, delta
end

def assert_elapsed_fake_time(seconds, delta=0.01, &block)
  with_fake_time do
    assert_elapsed_time(seconds, delta, &block)
  end
end
