require "eventbox/argument_sanitizer"
require "eventbox/event_loop"
require "eventbox/object_registry"

class Eventbox
  autoload :VERSION, "eventbox/version"

  include ArgumentSanitizer

  class InvalidAccess < RuntimeError; end
  class NoResult < RuntimeError; end
  class MultipleResults < RuntimeError; end

  private

  # Create a new Eventbox instance.
  #
  # The same thread which called Eventbox.new, must also call Eventbox#run.
  # It is possible to call asynchronous methods to the instance before calling #run .
  # They are processed as soon as #run is started.
  # It is also possible to call synchronous methods from a different thread.
  # These calls will block until #run is started.
  def initialize(*args, &block)
    threadpool = Thread

    # TODO Better hide instance variables

    # Verify that all public methods are properly wrapped
    obj = Object.new
    meths = methods - obj.methods - [:shutdown, :mutable_object]
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

    # Define an annonymous class which is used as execution context for actions.
    meths = public_methods - Object.new.methods - [:shutdown]
    selfobj = self

    # When called from action method, this class is used as execution environment for the newly created thread.
    # All calls to public methods are passed to the calling instance.
    @action_class = Class.new(self.class) do
      # Forward method calls.
      meths.each do |fwmeth|
        define_method(fwmeth) do |*fwargs, &fwblock|
          selfobj.send(fwmeth, *fwargs, &fwblock)
        end
      end
    end

    # Run the event loop thread in a separate class.
    # Otherwise it would block GC'ing of self.
    @input_queue = Queue.new
    loop_running = Queue.new
    @event_loop = EventLoop.new(@input_queue, loop_running, threadpool)
    ObjectSpace.define_finalizer(self, @event_loop.method(:shutdown))

    @ctrl_thread = loop_running.deq

    init(*args, &block)
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

  Callback = Struct.new :box, :args, :cbresult, :block
  CallbackResult = Struct.new :box, :res, :cbresult

  AsyncCall = Struct.new :box, :name, :args

  # Define a method for asynchronous (fire-and-forget) calls.
  #
  # The created method can be called from any thread.
  # The call is enqueued into the input queue of the control loop.
  # A call wakes the control loop started by #run , so that the method body is executed concurrently.
  # All parameters given to the are passed to the block as either copies or wrapped objects.
  # A marshalable object is passed as a deep copy through Marshal.dump and Marshal.load .
  # An object which faild to marshal is wrapped by Eventbox::MutableWrapper.
  # Access to the wrapped object from the control thread is denied, but the wrapper can be stored and passed to other actions.
  def self.async_call(name, &block)
    unbound_method = nil
    with_block_or_def(name, block) do |*args|
      if ::Thread.current==@ctrl_thread
        # Use the correct method within the class hierarchy, instead of just self.send(*args).
        # Otherwise super() would start an infinite recursion.
        unbound_method.bind(self).call(*args)
      else
        args = sanity_before_queue(args)
        @input_queue << AsyncCall.new(self, name, args)
      end
    end
    unbound_method = self.instance_method("__#{name}__")
  end

  SyncCall = Struct.new :box, :name, :args, :answer_queue

  # Define a method for synchronous calls.
  #
  # The created method can be called from any thread.
  # It is simular to #async_call , but the method doesn't return immediately, but waits until the method body is executed and returns its return value.
  #
  # The return value is passed either as a copy or as a unwrapped object.
  # The return value is therefore handled similar to parameters to #action .
  def self.sync_call(name, &block)
    unbound_method = nil
    with_block_or_def(name, block) do |*args|
      if ::Thread.current==@ctrl_thread
        unbound_method.bind(self).call(*args)
      else
        args = sanity_before_queue(args)
        answer_queue = Queue.new
        @input_queue << SyncCall.new(self, name, args, answer_queue)
        args = answer_queue.deq
        sanity_after_queue(args)
      end
    end
    unbound_method = self.instance_method("__#{name}__")
  end

  YieldCall = Struct.new :box, :name, :args, :answer_queue, :block

  # Define a method for synchronous calls with asynchronous result.
  #
  # The created method can be called from any thread.
  # It is simular to #sync_call , but not the result of the block is returned, but is returned per yield.
  #
  # The yielded value is passed either as a copy or as a unwrapped object.
  # The yielded value is therefore handled similar to parameters to #action .
  def self.yield_call(name, &block)
    unbound_method = nil
    with_block_or_def(name, block) do |*args, &cb|
      if ::Thread.current==@ctrl_thread
        result = nil
        unbound_method.bind(self).call(*args, proc do |*res|
          raise MultipleResults, "received multiple results for method `#{name}'" if result
          result = res
        end) do |*cbargs, &cbresult|
          cbres = cb.yield(*cbargs)
          cbresult.yield(cbres)
        end
        if result
          return return_args(result)
        else
          # The call didn't immediately yield a result, but the result could be deferred and yielded by a later event.
          # TODO
          raise NoResult, "no result yielded in `#{name}'"
        end
      else
        args = sanity_before_queue(args)
        answer_queue = Queue.new
        @input_queue << YieldCall.new(self, name, args, answer_queue, cb)
        loop do
          rets = answer_queue.deq
          case rets
          when Callback
            cbargs = sanity_after_queue(rets.args)
            cbres = rets.block.yield(*cbargs)
            cbres = sanity_before_queue(cbres)
            @input_queue << CallbackResult.new(rets.box, cbres, rets.cbresult)
          else
            answer_queue.close
            return sanity_after_queue(rets)
          end
        end
      end
    end
    unbound_method = self.instance_method("__#{name}__")
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

  # Force stop of the event loop and of all action threads
  #
  # Cleanup of threads will be done through the garbage collector otherwise.
  public def shutdown
    @event_loop.shutdown
  end

  ThreadFinished = Struct.new :thread

  # Run a block as asynchronous action.
  #
  # The action is executed through the threadpool given to #new .
  #
  # Each parameter is passed to the block either as a copy or as a unwrapped object.
  # A wrapper object (kind of Eventbox::MutableWrapper) is unwrapped before passed to the called block.
  # Any other object is passed as a deep copy through Marshal.dump and Marshal.load .
  #
  # Actions can return state changes or objects to the control loop by calls to methods created by #async_call, #sync_call or #yield_call.
  # To avoid shared objects, the action block doesn't have access to local variables, instance variables or instance methods other then methods defined per #async_call, #sync_call or #yield_call .
  #
  # An action can be started as named action like:
  #   action param1, tso(param2), def do_something(param1, param2)
  #     sleep 1
  #   end
  #
  # or as an anonnymous action like:
  #   action(param1, tso(param2)) do |o|
  #     def o.o(param1, param2)
  #       sleep 1
  #     end
  #   end
  #
  def action(*args, method_name)
    raise InvalidAccess, "action must be called from the event loop thread" if ::Thread.current!=@ctrl_thread

    sandbox = @action_class.allocate
    if block_given?
      args << method_name
      method_name = yield(sandbox)
      meth = sandbox.method(method_name)
    else
      # Verify that the method name didn't overwrite an existing method
      if @method_map[method_name]
        meth = method(method_name)
        raise InvalidAccess, "action method name `#{method_name}' at #{meth.source_location.join(":")} conflicts with instance methods"
      end

      meth = self.class.instance_method(method_name).bind(sandbox)
      meth.owner.send(:remove_method, method_name)
    end

    args = sanity_before_queue(args)
    # Start a new action thread
    @event_loop.start_action(meth, args)
    nil
  end
end
