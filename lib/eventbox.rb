require "weakref"
require "eventbox/sanitizer"
require "eventbox/boxable"
require "eventbox/event_loop"
require "eventbox/object_registry"

class Eventbox
  autoload :VERSION, "eventbox/version"
  autoload :ThreadPool, "eventbox/thread_pool"
  autoload :Timer, "eventbox/timer"

  extend Boxable

  class InvalidAccess < RuntimeError; end
  class MultipleResults < RuntimeError; end
  class AbortAction < RuntimeError; end

  if RUBY_ENGINE=='jruby' && RUBY_VERSION.split(".").map(&:to_i).pack("C*") < [9,2,1,0].pack("C*") ||
      RUBY_ENGINE=='truffleruby'
    # This is a workaround for bug https://github.com/jruby/jruby/issues/5314
    # which was fixed in JRuby-9.2.1.0.
    class Thread < ::Thread
      def initialize(*args, &block)
        started = Queue.new
        super do
          Thread.handle_interrupt(Exception => :never) do
            started << true
            block.call(*args)
            # Immediately stop the thread, before the handle_interrupt has finished.
            # This is necessary for JRuby to avoid possoble signal handling after the block.
            Thread.exit
          end
        end
        started.pop
      end
    end
  end

  # Retrieves the Eventbox options of this class.
  #
  # @return [Hash]  The options for instantiation of this class.
  # @see with_options
  def self.eventbox_options
    {
      threadpool: Thread,
      guard_time: 0.5,
    }
  end

  # Create a new derived class with the given options.
  #
  # The options are merged with the options of the base class.
  # The following options are available:
  #
  # @param threadpool [Object] A threadpool.
  #   Can be either +Thread+ (default) or a {Eventbox::Threadpool} instance.
  # @param guard_time Event scope methods should not do blocking operations.
  #   Eventbox measures the time of each call to event scope methods and warns, when it is exceeded.
  #   There are several ways to configure guard_time:
  #   * Set to +nil+: Disable measuring of time to process event scope methods.
  #   * Set to a +Numeric+ value: Maximum number of seconds allowed for event scope methods.
  #   * Set to a +Proc+ object: Called after each call to an event scope method.
  #     The +Proc+ object is called with the number of seconds the call took as first and the name as second argument.
  def self.with_options(**options)
    Class.new(self) do
      define_singleton_method(:eventbox_options) do
        super().merge(options)
      end

      def self.inspect
        klazz = self
        until name=klazz.name
          klazz = klazz.superclass
        end
        "#{name}#{eventbox_options}"
      end
    end
  end

  private

  # @private
  #
  # Create a new {Eventbox} instance.
  #
  # All arguments are passed to the init() method when defined.
  def initialize(*args, &block)
    options = self.class.eventbox_options

    # This instance variable is set to self here, but replaced by Boxable#action to a WeakRef
    @__eventbox__ = self

    # Verify that all public methods are properly wrapped and no unsafe methods exist
    # This check is done at the first instanciation only and doesn't slow down subsequently.
    # Since test and set operations aren't atomic, it can happen that the check is executed several times.
    # This is considered less harmful than slowing all instanciations down by a mutex.
    unless self.class.instance_variable_defined?(:@eventbox_methods_checked)
      self.class.instance_variable_set(:@eventbox_methods_checked, true)

      obj = Object.new
      meths = methods - obj.methods - [:__getobj__, :shutdown!, :shared_object]
      prmeths = private_methods - obj.private_methods
      prohib = meths.find do |name|
        !prmeths.include?(:"__#{name}__")
      end
      if prohib
        meth = method(prohib)
        raise InvalidAccess, "method `#{prohib}' at #{meth.source_location.join(":")} is not properly defined -> it must be created per async_call, sync_call, yield_call or private prefix"
      end
    end

    # Run the processing of calls (the event loop) in a separate class.
    # Otherwise it would block GC'ing of self.
    @__event_loop__ = EventLoop.new(options[:threadpool], options[:guard_time])
    ObjectSpace.define_finalizer(self, @__event_loop__.method(:send_shutdown))

    init(*args, &block)
  end

  def self.method_added(name)
    if name==:initialize
      meth = instance_method(:initialize)
      raise InvalidAccess, "method `initialize' at #{meth.source_location.join(":")} must not be overwritten - use `init' instead"
    end
  end

  # @private
  #
  # Provide access to the eventbox instance as either
  # - self within the eventbox instance itself or
  # - WeakRef.new(self).__getobj__ within actions.
  # This allows actions to be GC'ed, when the related Eventbox instance is no longer in use.
  def eventbox
    @__eventbox__.__getobj__
  end

  # @private
  protected def __getobj__
    self
  end

  private

  # Initialize a new {Eventbox} instance.
  #
  # This method is executed for initialization of a Eventbox instance.
  # This method receives all arguments given to +Eventbox.new+ after they have passed the {Sanitizer}.
  # It can be used like +initialize+ in ordinary ruby classes including +super+ to initialize included modules or base classes.
  #
  # {init} can be defined as either {sync_call} or {async_call} with no difference.
  # {init} can also be defined as {yield_call}, so that the +new+ call is blocked until the result is yielded.
  def init(*args)
  end

  # Create a proc object for asynchronous (fire-and-forget) calls similar to {async_call}.
  #
  # It can be passed to external scope and called from there like so:
  #
  #   class MyBox < Eventbox
  #     sync_call def print(p1)
  #       async_proc do |p2|
  #         puts "#{p1} #{p2}"
  #       end
  #     end
  #   end
  #   MyBox.new.print("Hello").call("world")   # Prints "Hello world"
  #
  # The created object can be safely called from any thread.
  # All block arguments are passed through the {Sanitizer}.
  # The block itself might not do any blocking calls or expensive computations - this would impair responsiveness of the {Eventbox} instance.
  # Instead use {Eventbox.action} in these cases.
  #
  # The block always returns +self+ to the caller.
  def async_proc(name=nil, &block)
    @__event_loop__.new_async_proc(name=nil, &block)
  end

  # Create a Proc object for synchronous calls similar to {sync_call}.
  #
  # It can be passed to external scope and called from there like so:
  #
  #   class MyBox < Eventbox
  #     sync_call def print(p1)
  #       sync_proc do |p2|
  #         "#{p1} #{p2}"
  #       end
  #     end
  #   end
  #   puts MyBox.new.print("Hello").call("world")   # Prints "Hello world"
  #
  # The created object can be safely called from any thread.
  # All block arguments as well as the result value are passed through the {Sanitizer}.
  # The block itself might not do any blocking calls or expensive computations - this would impair responsiveness of the {Eventbox} instance.
  # Instead use {Eventbox.action} in these cases.
  #
  # This Proc is simular to {async_proc}, but when the block is invoked, it is executed and it's return value is returned to the caller.
  # Since all processing within the event scope of an {Eventbox} instance must not execute blocking operations, sync procs can only return immediate values.
  # For deferred results use {yield_proc} instead.
  def sync_proc(name=nil, &block)
    @__event_loop__.new_sync_proc(name=nil, &block)
  end

  # Create a Proc object for calls with deferred result similar to {yield_call}.
  #
  # It can be passed to external scope and called from there like so:
  #
  #   class MyBox < Eventbox
  #     sync_call def print(p1)
  #       yield_proc do |p2, result|
  #         result.yield "#{p1} #{p2}"
  #       end
  #     end
  #   end
  #   puts MyBox.new.print("Hello").call("world")   # Prints "Hello world"
  #
  # This proc type is simular to {sync_proc}, however it's not the result of the block that is returned.
  # Instead the block is called with one additional argument in the event scope, which is used to yield a result value.
  # The result value can be yielded within the called block, but it can also be called by any other event scope or external method, leading to a deferred proc return.
  # The external thread calling this proc is suspended until a result is yielded.
  # However the Eventbox object keeps responsive to calls from other threads.
  #
  # The created object can be safely called from any thread.
  # If yield procs are called in the event scope, they must get a Proc object as the last argument.
  # It is called when a result was yielded.
  #
  # All block arguments as well as the result value are passed through the {Sanitizer}.
  # The block itself might not do any blocking calls or expensive computations - this would impair responsiveness of the {Eventbox} instance.
  # Instead use {Eventbox.action} in these cases.
  def yield_proc(name=nil, &block)
    @__event_loop__.new_yield_proc(name=nil, &block)
  end

  # Mark an object as to be shared instead of copied.
  #
  # A marked object is never passed as copy, but passed as reference.
  # The object is therefore wrapped as {WrappedObject} when used in an unsafe scope.
  # Wrapping as {WrappedObject} denies access from external scope to event scope objects and vice versa.
  # It also denies access to objects originated from a foreign event scope.
  # However the object can be passed as reference and is automatically unwrapped when passed back to the original scope.
  # It can therefore be used to modify the original object even after traversing the boundary.
  #
  # Wrapping and unwrapping works even if the shared object is stored within another object as instance variable or within a collection class.
  #
  # The mark is stored for the lifetime of the object, so that it's enough to mark only once at object creation.
  public def shared_object(object)
    @__event_loop__.shared_object(object)
  end

  # Force stop of all action threads spawned by this {Eventbox} instance
  #
  # Cleanup of threads will be done through the garbage collector otherwise.
  # However in some cases automatic garbage collection doesn't remove all instances due to running action threads.
  # Calling shutdown! when the work of the instance is done, ensures that it is GC'ed in all cases.
  #
  # If {shutdown!} is called externally, it blocks until all actions threads terminated.
  #
  # If {shutdown!} is called in the event scope, it just triggers the termination of all action threads and returns afterwards.
  # Optionally {shutdown!} can be called with a block.
  # It is called when all actions threads terminated.
  public def shutdown!(&completion_block)
    @__event_loop__.shutdown(&completion_block)
  end
end
