require "weakref"
require "eventbox/argument_sanitizer"
require "eventbox/event_loop"
require "eventbox/object_registry"

class Eventbox
  autoload :VERSION, "eventbox/version"
  autoload :ThreadPool, "eventbox/thread_pool"

  include ArgumentSanitizer

  class InvalidAccess < RuntimeError; end
  class MultipleResults < RuntimeError; end
  class AbortAction < RuntimeError; end

  # The options for instantiation of this class.
  def self.eventbox_options
    {
      threadpool: Thread,
      guard_time: 0.1,
    }
  end

  # Create a new derived class with the given options.
  #
  # The options are merged with the options of the base class.
  # See eventbox_options for available options.
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

  # Create a new Eventbox instance.
  #
  # All arguments are passed to the init() method when defined.
  def initialize(*args, &block)
    threadpool = self.class.eventbox_options[:threadpool]

    # TODO Better hide instance variables
    @eventbox = self

    # Verify that all public methods are properly wrapped
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

    # Prepare list of prohibited method names for action
    prmeths = private_methods + protected_methods + public_methods - obj.private_methods - obj.protected_methods - obj.public_methods
    @method_map = prmeths.each.with_object({}) { |name, hash| hash[name] = true }

    # Run the processing of calls (the event loop) in a separate class.
    # Otherwise it would block GC'ing of self.
    @event_loop = EventLoop.new(threadpool, self.class.eventbox_options[:guard_time])
    ObjectSpace.define_finalizer(self, @event_loop.method(:shutdown))

    init(*args, &block)
  end

  # Used in ArgumentSanitizer
  attr_reader :event_loop

  # Provide access to the eventbox instance as either
  # - self within the eventbox instance itself or
  # - WeakRef.new(self).__getobj__ within actions.
  # This allows actions to be GC'ed, when the related Eventbox instance is no longer in use.
  def eventbox
    @eventbox.__getobj__
  end

  protected def __getobj__
    self
  end

  private

  # This method is executed when the event loop is up and running.
  #
  # Derive this method for initialization.
  def init(*args)
  end

  def self.with_block_or_def(name, block, &cexec)
    if block
      define_method(name, &cexec)
      private define_method("__#{name}__", &block)
    else
      alias_method("__#{name}__", name)
      private("__#{name}__")
      remove_method(name)
      define_method(name, &cexec)
    end
  end

  # Define a threadsafe method for asynchronous (fire-and-forget) calls.
  #
  # The created method can be safely called from any thread.
  # All method arguments are passed through the ArgumentSanitizer.
  # The method itself might not do any blocking calls or extensive computations - this would impair responsiveness of the Eventbox instance.
  # Instead use Eventbox#action in these cases.
  #
  # The method always returns +self+ to the caller.
  def self.async_call(name, &block)
    unbound_method = nil
    with_block_or_def(name, block) do |*args, &cb|
      if @event_loop.internal_thread?
        # Use the correct method within the class hierarchy, instead of just self.send(*args).
        # Otherwise super() would start an infinite recursion.
        unbound_method.bind(eventbox).call(*args) do |*cbargs|
          cb.yield(*cbargs)
        end
      else
        args = sanity_before_queue(args, name)
        cb = sanity_before_queue(cb, name)
        @event_loop.async_call(eventbox, name, args, cb)
      end
    end
    unbound_method = self.instance_method("__#{name}__")
    name
  end

  # Define a method for synchronous calls.
  #
  # The created method can be safely called from any thread.
  # It is simular to #async_call , but the method waits until the method body is executed and returns its return value.
  # Since all internal processing within a Eventbox instance must not involve blocking operations, sync calls can only return immediate values.
  # For deferred results use {yield_call} instead.
  #
  # All method arguments as well as the result value are passed through the ArgumentSanitizer.
  def self.sync_call(name, &block)
    unbound_method = nil
    with_block_or_def(name, block) do |*args, &cb|
      if @event_loop.internal_thread?
        unbound_method.bind(eventbox).call(*args) do |*cbargs|
          cb.yield(*cbargs)
        end
      else
        args = sanity_before_queue(args, name)
        cb = sanity_before_queue(cb, name)
        answer_queue = Queue.new
        @event_loop.sync_call(eventbox, name, args, answer_queue, cb)
        callback_loop(answer_queue)
      end
    end
    unbound_method = self.instance_method("__#{name}__")
    name
  end

  # Define a method for calls with deferred result.
  #
  # The created method can be safely called from any external thread.
  # However yield calls can't be invoked internally (since deferred results require non-sequential program execution).
  #
  # This call type is simular to #sync_call , however it's not the result of the method that is returned.
  # Instead the method is called with one additional argument internally, which is used to yield a result value.
  # The result value can be yielded within the called method, but it can also be called by any other internal or external method, leading to a deferred method return.
  # The external thread calling this method is suspended until a result is yielded.
  #
  # All method arguments as well as the result value are passed through the ArgumentSanitizer.
  def self.yield_call(name, &block)
    with_block_or_def(name, block) do |*args, &cb|
      if @event_loop.internal_thread?
        raise InvalidAccess, "yield_call `#{name}' can not be called internally - use sync_call or async_call instead"
      else
        args = sanity_before_queue(args, name)
        cb = sanity_before_queue(cb, name)
        answer_queue = Queue.new
        @event_loop.yield_call(eventbox, name, args, answer_queue, cb)
        callback_loop(answer_queue)
      end
    end
    name
  end

  # Threadsafe write access to instance variables.
  def self.attr_writer(name)
    async_call("#{name}=") do |value|
      instance_variable_set("@#{name}", value)
    end
  end

  # Threadsafe read access to instance variables.
  def self.attr_reader(name)
    sync_call("#{name}") do
      instance_variable_get("@#{name}")
    end
  end

  # Threadsafe read and write access to instance variables.
  #
  # Attention: Be careful with read-modify-write operations - they are *not* atomic!
  #
  # This will lose counter increments:
  #   attr_accessor :counter
  #   async_call def start
  #     10.times do
  #       action def do_something
  #         self.counter += 1
  #       end
  #     end
  #   end
  #
  # Instead do increments in one method call like so:
  #   async_call def start
  #     10.times do
  #       action def do_something
  #         increment 1
  #       end
  #     end
  #   end
  #   async_call def increment(by)
  #     @counter += by
  #   end
  def self.attr_accessor(name)
    attr_reader name
    attr_writer name
  end

  # Create a proc object for asynchronous (fire-and-forget) calls similar to {async_call}.
  #
  # The created object can be safely called from any thread.
  # All block arguments are passed through the ArgumentSanitizer.
  # The block itself might not do any blocking calls or extensive computations - this would impair responsiveness of the Eventbox instance.
  # Instead use Eventbox#action in these cases.
  #
  # The block always returns +self+ to the caller.
  def async_proc(name=nil, &block)
    @event_loop.new_async_proc(name=nil, &block)
  end

  # Create a Proc object for synchronous calls similar to {sync_call}.
  #
  # The created object can be safely called from any thread.
  # All block arguments are passed through the ArgumentSanitizer.
  # The block itself might not do any blocking calls or extensive computations - this would impair responsiveness of the Eventbox instance.
  # Instead use Eventbox#action in these cases.
  #
  # This Proc is simular to #async_proc , but when the block is invoked, it is executed and it's return value is returned to the caller.
  # Since all internal processing within a Eventbox instance must not involve blocking operations, sync procs can only return immediate values.
  # For deferred results use {yield_proc} instead.
  #
  # All method arguments as well as the result value are passed through the ArgumentSanitizer.
  def sync_proc(name=nil, &block)
    @event_loop.new_sync_proc(name=nil, &block)
  end

  # Create a Proc object for calls with deferred result similar to {yield_call}.
  #
  # The created object can be safely called from any external thread.
  # However yield procs can't be invoked internally (since deferred results require non-sequential program execution).
  #
  # This proc type is simular to #sync_proc , however it's not the result of the block that is returned.
  # Instead the block is called with one additional argument internally, which is used to yield a result value.
  # The result value can be yielded within the called block, but it can also be called by any other internal or external method, leading to a deferred proc return.
  # The external thread calling this proc is suspended until a result is yielded.
  #
  # All method arguments as well as the result value are passed through the ArgumentSanitizer.
  def yield_proc(name=nil, &block)
    @event_loop.new_yield_proc(name=nil, &block)
  end

  # Force stop of all action threads spawned by this Eventbox instance
  #
  # Cleanup of threads will be done through the garbage collector otherwise.
  # However in some cases automatic garbage collection doesn't remove all instances due to running action threads.
  # Calling shutdown! when the work of the instance is done, ensures that it is GC'ed in all cases.
  public def shutdown!
    @event_loop.shutdown
  end

  ThreadFinished = Struct.new :thread

  # Run a block as asynchronous action.
  #
  # The action is executed through the threadpool given to {with_options}.
  #
  # All method arguments are passed through the ArgumentSanitizer.
  #
  # Actions can return state changes or objects to the event loop by calls to methods created by #async_call, #sync_call or #yield_call or through calling async_proc, sync_proc or yield_proc objects.
  # To avoid unsafe shared objects, the action block doesn't have access to local variables, instance variables or instance methods other then methods defined per #async_call, #sync_call or #yield_call .
  #
  # An action can be started as named action like:
  #   action param1, param2, def do_something(param1, param2)
  #     sleep 1
  #   end
  #
  # or as an anonnymous action (deprecated) like:
  #   action(param1, param2) do |o|
  #     def o.o(param1, param2)
  #       sleep 1
  #     end
  #   end
  #
  # {action} returns an Action object.
  # It can be used to interrupt the program execution by an exception.
  # See {Eventbox::Action} for further information.
  # If the action method accepts one more argument than given to the {action} call, it is set to corresponding {Action} instance:
  #   action param1, def do_something(param1, action)
  #     # pass `action' to some internal or external method,
  #     # so that it's able to send a signal per Action#raise
  #   end
  #
  def action(*args)
    raise InvalidAccess, "action must be called from the event loop thread" unless @event_loop.internal_thread?

    sandbox = self.class.allocate
    sandbox.instance_variable_set(:@event_loop, @event_loop)
    sandbox.instance_variable_set(:@eventbox, WeakRef.new(self))
    if block_given?
      method_name = yield(sandbox)
      meth = sandbox.method(method_name)
    else
      method_name = args.pop
      # Verify that the method name didn't overwrite an existing method
      if @method_map[method_name]
        meth = method(method_name)
        raise InvalidAccess, "action method name `#{method_name}' at #{meth.source_location.join(":")} conflicts with instance methods"
      end

      meth = self.class.instance_method(method_name).bind(sandbox)
      meth.owner.send(:remove_method, method_name)
    end

    args = sanity_before_queue(args)
    # Start a new action thread and return an Action instance
    @event_loop._start_action(meth, args)
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
  #     a = action def sleepy
  #       Thread.handle_interrupt(MySignal => :on_blocking) do
  #         sleep
  #       end
  #     rescue MySignal
  #       puts "well-rested"
  #     end
  #     a.raise(MySignal)
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
    # If the action has already finished, this method does nothing.
    def raise(*args)
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
  end
end
