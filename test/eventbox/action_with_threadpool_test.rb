require_relative "../test_helper"

class EventboxActionWithThreadpoolTest < Minitest::Test
  include Minitest::Hooks

  # JRuby doesn't GC the threads reliably, so that more threads are needed
  num_threads = RUBY_ENGINE == "jruby" ? 120 : 4
  Eventbox = ::Eventbox.with_options(threadpool: Eventbox::ThreadPool.new(num_threads, run_gc_when_busy: true))

  eval_file "eventbox/action_test_collection.rb"

  def after_all
    super
    Eventbox.eventbox_options[:threadpool].shutdown!
  end
end
