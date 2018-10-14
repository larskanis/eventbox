require "weakref"
require "eventbox/argument_sanitizer"
require "eventbox/boxable"
require "eventbox/event_loop"
require "eventbox/object_registry"

class Eventbox
  autoload :VERSION, "eventbox/version"
  autoload :ThreadPool, "eventbox/thread_pool"
  autoload :Timer, "eventbox/timer"

  extend Boxable
  include ArgumentSanitizer

  class InvalidAccess < RuntimeError; end
  class MultipleResults < RuntimeError; end
  class AbortAction < RuntimeError; end

  # Retrieves the Eventbox options of this class.
  #
  # @return [Hash]  The options for instantiation of this class.
  # @see with_options
  def self.eventbox_options
    {
      threadpool: Thread,
      guard_time: 0.1,
    }
  end

  # Create a new derived class with the given options.
  #
  # The options are merged with the options of the base class.
  # The following options are available:
  #
  # @param threadpool [Object] A threadpool.
  #   Can be either +Thread+ (default) or a {Eventbox::Threadpool} instance.
  # @param guard_time Internal methods should not do blocking operations.
  #   Eventbox measures the time of each call to internal methods and warns, when it is exceeded.
  #   There are several ways to configure guard_time:
  #   Set to +nil+: Disable measuring of time to process internal methods.
  #   Set to a +Numeric+ value: Maximum number of seconds allowed for internal methods.
  #   Set to a +Proc+ object: Called after each call to an internal method.
  #   The +Proc+ object is called with the number of seconds the call took as first and the name as second argument.
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

  # Create a new {Eventbox} instance.
  #
  # All arguments are passed to the init() method when defined.
  def initialize(*args, &block)
    options = self.class.eventbox_options

    # TODO Better hide instance variables
    @eventbox = self

    # Verify that all public methods are properly wrapped and no unsafe methods exist
    # This check is done at the first instanciation only and doesn't slow down subsequently.
    # Since test and set operations aren't atomic, it can happen that the check is executed several times.
    # This is considered less harmful than slowing all instanciations down by a mutex.
    unless self.class.instance_variable_defined?(:@eventbox_methods_checked)
      self.class.instance_variable_set(:@eventbox_methods_checked, true)

      obj = Object.new
      meths = methods - obj.methods - [:__getobj__, :shutdown!, :mutable_object]
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
    @event_loop = EventLoop.new(options[:threadpool], options[:guard_time])
    ObjectSpace.define_finalizer(self, @event_loop.method(:shutdown))

    init(*args, &block)
  end

  # @private
  #
  # Used in ArgumentSanitizer
  def event_loop
    @event_loop
  end

  # @private
  #
  # Provide access to the eventbox instance as either
  # - self within the eventbox instance itself or
  # - WeakRef.new(self).__getobj__ within actions.
  # This allows actions to be GC'ed, when the related Eventbox instance is no longer in use.
  def eventbox
    @eventbox.__getobj__
  end

  # @private
  protected def __getobj__
    self
  end

  private

  # This method is executed for initialization of a Eventbox instance.
  #
  # It can be used like +initialize+ in ordinary ruby classes.
  def init(*args)
  end

  # Create a proc object for asynchronous (fire-and-forget) calls similar to {async_call}.
  #
  # The created object can be safely called from any thread.
  # All block arguments are passed through the {ArgumentSanitizer}.
  # The block itself might not do any blocking calls or extensive computations - this would impair responsiveness of the {Eventbox} instance.
  # Instead use {Eventbox.action} in these cases.
  #
  # The block always returns +self+ to the caller.
  def async_proc(name=nil, &block)
    @event_loop.new_async_proc(name=nil, &block)
  end

  # Create a Proc object for synchronous calls similar to {sync_call}.
  #
  # The created object can be safely called from any thread.
  # All block arguments as well as the result value are passed through the {ArgumentSanitizer}.
  # The block itself might not do any blocking calls or extensive computations - this would impair responsiveness of the {Eventbox} instance.
  # Instead use {Eventbox.action} in these cases.
  #
  # This Proc is simular to {async_proc}, but when the block is invoked, it is executed and it's return value is returned to the caller.
  # Since all internal processing within a {Eventbox} instance must not involve blocking operations, sync procs can only return immediate values.
  # For deferred results use {yield_proc} instead.
  def sync_proc(name=nil, &block)
    @event_loop.new_sync_proc(name=nil, &block)
  end

  # Create a Proc object for calls with deferred result similar to {yield_call}.
  #
  # The created object can be safely called from any external thread.
  # However yield procs can't be invoked internally (since deferred results require non-sequential program execution).
  #
  # This proc type is simular to {sync_proc}, however it's not the result of the block that is returned.
  # Instead the block is called with one additional argument internally, which is used to yield a result value.
  # The result value can be yielded within the called block, but it can also be called by any other internal or external method, leading to a deferred proc return.
  # The external thread calling this proc is suspended until a result is yielded.
  #
  # All block arguments as well as the result value are passed through the {ArgumentSanitizer}.
  def yield_proc(name=nil, &block)
    @event_loop.new_yield_proc(name=nil, &block)
  end

  # Force stop of all action threads spawned by this {Eventbox} instance
  #
  # Cleanup of threads will be done through the garbage collector otherwise.
  # However in some cases automatic garbage collection doesn't remove all instances due to running action threads.
  # Calling shutdown! when the work of the instance is done, ensures that it is GC'ed in all cases.
  public def shutdown!
    @event_loop.shutdown
  end

  # An Action object is returned by {Eventbox#action} and optionally passed as last argument. It can be used to interrupt the program execution by an exception.
  #
  # However in contrast to ruby's builtin threads, by default any exceptions sent to the action thread are delayed until a code block is reached which explicit allows interruption.
  # The only exception which is delivered to the action thread by default is {Eventbox::AbortAction}.
  # It is raised by {shutdown} and is delivered as soon as a blocking operation is executed.
  #
  # An Action object can be used to stop the action while blocking operations.
  # Make sure, that the `rescue` statement is outside of the block to `handle_interrupt`.
  # Otherwise it could happen, that the rescuing code is interrupted by the signal.
  # Sending custom signals to an action works like:
  #
  #   class MySignal < Interrupt
  #   end
  #
  #   async_call def init
  #     a = start_sleep
  #     a.raise(MySignal)
  #   end
  #
  #   action def start_sleep
  #     Thread.handle_interrupt(MySignal => :on_blocking) do
  #       sleep
  #     end
  #   rescue MySignal
  #     puts "well-rested"
  #   end
  class Action
    include ArgumentSanitizer
    attr_reader :name

    def initialize(name, thread, event_loop)
      @name = name
      @thread = thread
      @event_loop = event_loop
    end

    attr_reader :event_loop
    private :event_loop

    # Send a signal to the running action.
    #
    # The signal must be kind of Exception.
    # See {Action} about asynchronous delivery of signals.
    #
    # This method does nothing if the action is already finished.
    def raise(*args)
      # ignore raise, if sent from the action thread
      if AbortAction === args[0] || (Module === args[0] && args[0].ancestors.include?(AbortAction))
        ::Kernel.raise InvalidAccess, "Use of Eventbox::AbortAction is not allowed - use Action#abort or a custom exception subclass"
      end

      if @event_loop.internal_thread?(@thread)
        args = sanity_before_queue(args)
        args = sanity_after_queue(args, @thread)
      end
      @thread.raise(*args)
    end

    # Send a AbortAction to the running thread.
    def abort
      @thread.raise AbortAction
    end

    # Belongs the current thread to this action.
    def current?
      @thread.respond_to?(:current?) ? @thread.current? : (@thread == Thread.current)
    end
  end
end
