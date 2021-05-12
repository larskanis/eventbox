# frozen-string-literal: true

class Eventbox
  module CallContext
    # @private
    def __answer_queue__
      @__answer_queue__
    end

    # @private
    attr_writer :__answer_queue__
  end

  class BlockingExternalCallContext
    include CallContext
  end

  class ActionCallContext
    include CallContext

    # @private
    def initialize(event_loop)
      answer_queue = Queue.new
      meth = proc do
        event_loop.callback_loop(answer_queue, nil, self.class)
      end
      @action = event_loop.start_action(meth, self.class, [])

      def answer_queue.gc_stop(object_id)
        close
      end
      ObjectSpace.define_finalizer(self, answer_queue.method(:gc_stop))

      @__answer_queue__ = answer_queue
    end

    # The action that drives the call context.
    attr_reader :action

    # Terminate the call context and the driving action.
    #
    # The method returns immediately and the corresponding action is terminated asynchonously.
    def shutdown!
      @__answer_queue__.close
    end
  end
end
