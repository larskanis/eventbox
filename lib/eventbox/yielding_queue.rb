class Eventbox
  class YieldingQueue
    def initialize(&block)
      @mutex = Mutex.new
      @block = block
    end

    def <<(value)
      @mutex.synchronize do
        @block.yield(value)
      end
    end
  end
end
