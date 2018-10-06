require_relative "../test_helper"

class EventboxActionWithThreadpoolTest < Minitest::Test
  Eventbox = ::Eventbox.with_options(threadpool: Eventbox::ThreadPool.new(3, run_gc_when_busy: true))

  eval_file "eventbox/action_test_collection.rb"

end
