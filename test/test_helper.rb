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
      line = th.backtrace&.find{|t| t=~/test\// } or
          th.backtrace&.find{|t| !(t=~/lib\/eventbox(\/|\.rb:)/) } or
          th.backtrace&.first
      warn "    #{ line }"
    end
  end
}

$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "eventbox"
require "minitest/autorun"

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

def eval_file(local_file)
  fn = File.expand_path(local_file, __dir__)
  class_eval(File.read(fn, encoding: "UTF-8"), fn)
end
