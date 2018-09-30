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
    threadpool = self.class.eventbox_options.fetch(:threadpool)

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
    @event_loop = EventLoop.new(threadpool)
    ObjectSpace.define_finalizer(self, @event_loop.method(:shutdown))

    init(*args, &block)
  end

  attr_reader :event_loop

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

  # Define a method for asynchronous (fire-and-forget) calls.
  #
  # The created method can be called safely from any thread.
  # All call arguments are passed as either copies or wrapped objects.
  # A marshalable object is passed as a deep copy through Marshal.dump and Marshal.load .
  # An object which faild to marshal is wrapped by Eventbox::ExternalObject.
  # Access to the external object from the event loop is denied, but the wrapper object can be stored and returned by methods or passed to actions.
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
  # The created method can be called safely from any thread.
  # It is simular to #async_call , but the method doesn't return immediately, but waits until the method body is executed and returns its return value.
  #
  # The return value is passed either as a copy or as a unwrapped object.
  # The return value is therefore handled similar to arguments to #action .
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

  # Define a method for synchronous calls with asynchronous result.
  #
  # The created method can be called safely from any thread.
  # It is simular to #sync_call , but not the result of the block is returned, but is returned per yield.
  #
  # The yielded value is passed either as a copy or as a unwrapped object.
  # The yielded value is therefore handled similar to arguments to #action .
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

  def self.attr_writer(name)
    async_call("#{name}=") do |value|
      instance_variable_set("@#{name}", value)
    end
  end
  def self.attr_reader(name)
    sync_call("#{name}") do
      instance_variable_get("@#{name}")
    end
  end
  def self.attr_accessor(name)
    attr_reader name
    attr_writer name
  end

  def async_proc(name=nil, &block)
    @event_loop.new_async_proc(name=nil, &block)
  end

  def sync_proc(name=nil, &block)
    @event_loop.new_sync_proc(name=nil, &block)
  end

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
  # Each argument is passed to the block either as a copy or as a unwrapped object.
  # A wrapper object (kind of Eventbox::MutableWrapper) is unwrapped before passed to the called block.
  # Any other object is passed as a deep copy through Marshal.dump and Marshal.load .
  #
  # Actions can return state changes or objects to the event loop by calls to methods created by #async_call, #sync_call or #yield_call or through calling async_proc, sync_proc or yield_proc objects.
  # To avoid unsafe shared objects, the action block doesn't have access to local variables, instance variables or instance methods other then methods defined per #async_call, #sync_call or #yield_call .
  #
  # An action can be started as named action like:
  #   action param1, tso(param2), def do_something(param1, param2)
  #     sleep 1
  #   end
  #
  # or as an anonnymous action (deprecated) like:
  #   action(param1, tso(param2)) do |o|
  #     def o.o(param1, param2)
  #       sleep 1
  #     end
  #   end
  #
  # {action} returns an Action object.
  # It can be used to interrupt the program execution by an exception.
  # See {Eventbox::Action} for further information.
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
end
