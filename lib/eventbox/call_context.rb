# frozen-string-literal: true

class Eventbox
  module CallContext
    # @private
    def __answer_queue__
      @__answer_queue__
    end

    # @private
    attr_writer :__answer_queue__

    def [](obj, method, *args)
      cc = CallChain.new(@__answer_queue__)
      obj.send(method, *args, cc.result_proc)
      cc
    end
  end

  class CallChain
    include CallContext

    # @private
    def initialize(answer_queue)
      @__answer_queue__ = answer_queue
      @result = nil
      @result_proc = proc do |res|
        if @block
          obj, method, *args = @block.call(res)
          obj.send(method, *args, @cc.result_proc)
          @block = nil
        else
          @result = res
          @result_proc = nil
        end
      end
    end

    # @private
    attr_reader :result_proc

    def then(&block)
      cc = CallChain.new(@__answer_queue__)
      if @result_proc
        @block = block
        @cc = cc
      else
        obj, method, *args = yield(@result)
        obj.send(method, *args, cc.result_proc)
        @result = nil
      end
      cc
    end
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
        event_loop.callback_loop(answer_queue, event_loop, self.class)
      end
      @action = event_loop.start_action(meth, self.class, [])

      def answer_queue.gc_stop(object_id)
        enq nil
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
      @__answer_queue__.enq nil unless @__answer_queue__.closed?
    end
  end
end
