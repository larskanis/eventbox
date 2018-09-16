class Eventbox
  autoload :VERSION, "eventbox/version"

  class InvalidAccess < RuntimeError; end
  class NoResult < RuntimeError; end

  private

  def self.return_args(args)
    args.length <= 1 ? args.first : args
  end

  # Create a new Eventbox instance.
  #
  # The same thread which called Eventbox.new, must also call Eventbox#run.
  # It is possible to call asynchronous methods to the instance before calling #run .
  # They are processed as soon as #run is started.
  # It is also possible to call synchronous methods from a different thread.
  # These calls will block until #run is started.
  def initialize(*args, &block)
    threadpool = Thread
    loop_running = Queue.new

    @threads = ThreadRegistry.new
    ObjectSpace.define_finalizer(self, @threads.method(:stop_all))

    @threads.loop_thread = threadpool.new do
      # TODO Better hide these instance variables for derived classes:
      @exit_run = nil
      @threadpool = threadpool
      @ctrl_thread = Thread.current
      @input_queue = Queue.new

      # Verify that all public methods are properly wrapped
      obj = Object.new
      meths = methods - obj.methods - [:run, :mo, :mutable_object]
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
      meths = public_methods - Object.new.methods - [:run]
      selfobj = self

      # When called from action method, this class is used as execution environment for the newly created thread.
      # All calls to public methods are passed to the calling instance.
      @action_class = Class.new(self.class) do

        # Overwrite the usual initialization.
        def initialize
        end

        # Forward method calls.
        meths.each do |fwmeth|
          define_method(fwmeth) do |*fwargs, &fwblock|
            selfobj.send(fwmeth, *fwargs, &fwblock)
          end
        end
      end

      loop_running << true
      run
    end

    loop_running.deq

    init(*args, &block)
  end

  private

  # This method is executed when the event loop is up and running.
  #
  # Derive this method for initialization.
  def init(*args)
  end

  # This method is executed whenever one or more input events have been processed.
  #
  # Derive this method for any polling activity.
  def repeat
    # can be derived
  end

  class ThreadRegistry
    class ThreadRegistryAlreadyStopped < RuntimeError
    end

    def initialize
      @mutex = Mutex.new
      @action_threads = {}
      @stopped = false
    end

    private def check_stopped
      if @stopped
        raise ThreadRegistryAlreadyStopped, "threads were already stopped"
      end
    end

    def loop_thread=(th)
      @mutex.synchronize do
        check_stopped
        @loop_thread = th
      end
    end

    def add_action_thread(thread)
      @mutex.synchronize do
        check_stopped
        @action_threads[thread] = true
      end
    end

    def rm_action_thread(thread)
      @mutex.synchronize do
        check_stopped
        @action_threads.delete(thread)
      end
    end

    def stop_all(object_id=nil)
      @mutex.synchronize do
        return if @stopped
        @loop_thread.kill
        @loop_thread = nil
      end
      stop_action_threads
    end

    def stop_action_threads
      # terminate all running action threads
      @mutex.synchronize do
        return if @stopped
        check_stopped
        @action_threads.each do |th, _|
          th.exit
        end
        @action_threads = []
        @stopped = true
      end
    end
  end

  # Run the event loop.
  #
  # The event loop processes the input queue by executing the enqueued method calls.
  # It can be stopped by #exit_run .
  def run
    raise InvalidAccess, "run must be called from the same thread as new" if ::Thread.current!=@ctrl_thread

    until @exit_run
      begin
        process_input_queue
      end until @input_queue.empty?

      repeat
    end

    @threads.stop_action_threads

    # TODO Closing the queue leads to ClosedQueueError on JRuby due to enqueuing of ThreadFinished objects.
    # @input_queue.close

    @exit_return_value
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

  AsyncCall = Struct.new :name, :args

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
        @input_queue << AsyncCall.new(name, args)
      end
    end
    unbound_method = self.instance_method("__#{name}__")
  end

  SyncCall = Struct.new :name, :args, :answer_queue

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
        @input_queue << SyncCall.new(name, args, answer_queue)
        args = answer_queue.deq
        sanity_after_queue(args)
      end
    end
    unbound_method = self.instance_method("__#{name}__")
  end

  YieldCall = Struct.new :name, :args, :answer_queue

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
        unbound_method.bind(self).call(*args, proc do |*res|
          return self.class.return_args(res)
        end) do |*cbargs, &cbresult|
          cbres = cb.yield(*cbargs)
          cbresult.yield(cbres)
        end
        raise NoResult, "no result yielded"
      else
        args = sanity_before_queue(args)
        answer_queue = Queue.new
        @input_queue << YieldCall.new(name, args, answer_queue)
        loop do
          rets = answer_queue.deq
          case rets
          when Callback
            cbargs = sanity_after_queue(rets.args)
            cbres = cb.yield(*cbargs)
            cbres = sanity_before_queue(cbres)
            @input_queue << CallbackResult.new(cbres, rets.cbresult)
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

  # Stop the control loop started by #run .
  async_call :shutdown! do |*values|
    @exit_run = true
    @exit_return_value = self.class.return_args(values)
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
    raise InvalidAccess, "action must be called from the same thread as new" if ::Thread.current!=@ctrl_thread

    sandbox = @action_class.new
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
    new_thread = @threadpool.new do
      args = sanity_after_queue(args)

      meth.call(*args)
      @input_queue << ThreadFinished.new(Thread.current)
    end

    @threads.add_action_thread(new_thread)
    nil
  end

  public

  class InternalObject < Object
    def initialize(object, thread)
      @object = object
      @thread = thread
    end

    def access_allowed?
      ::Thread.current == @thread
    end

    def object
      raise InvalidAccess, "access to internal object #{@object.inspect} not allowed outside of the event loop" unless access_allowed?
      @object
    end
  end

  class ExternalObject < Object
    def initialize(object, thread)
      @object = object
      @thread = thread
    end

    def access_allowed?
      ::Thread.current != @thread
    end

    def object
      raise InvalidAccess, "access to external object #{@object.inspect} not allowed in the event loop" unless access_allowed?
      @object
    end
  end

  def mutable_object(object)
    if Thread.current == @ctrl_thread
      @@object_registry.set_tag(object, @ctrl_thread)
    else
      @@object_registry.set_tag(object, :extern)
    end
    object
  end
  alias mo mutable_object

  private

  class ObjectRegistry
    def initialize
      @objects = {}
      @mutex = Mutex.new
    end

    def taggable?(object)
      case object
      when Integer, InternalObject, ExternalObject
        false
      else
        true
      end
    end

    def set_tag(object, owning_thread)
      raise InvalidAccess, "object is not taggable: #{object.inspect}" unless taggable?(object)
      @mutex.synchronize do
        tag = @objects[object.object_id]
        if tag && tag != owning_thread
          raise InvalidAccess, "object #{object.inspect} is already tagged to #{tag.inspect}"
        end
        @objects[object.object_id] = owning_thread
      end
      ObjectSpace.define_finalizer(object, method(:untag))
    end

    def get_tag(object)
      @mutex.synchronize do
        @objects[object.object_id]
      end
    end

    def untag(object_id)
      @mutex.synchronize do
        @objects.delete(object_id)
      end
    end
  end
  @@object_registry = ObjectRegistry.new

  def sanity_before_queue(args)
    pr = proc do |arg|
      case arg
      # If object is already wrapped -> pass through
      when InternalObject, ExternalObject
        arg
      else
        # Check if the object has been tagged
        case @@object_registry.get_tag(arg)
        when Thread
          InternalObject.new(arg, @ctrl_thread)
        when :extern
          ExternalObject.new(arg, @ctrl_thread)
        else
          # Not tagged -> try to deep copy the object
          begin
            dumped = Marshal.dump(arg)
          rescue TypeError
            # Object not copyable -> wrap object as internal or external object
            if Thread.current == @ctrl_thread
              InternalObject.new(arg, @ctrl_thread)
            else
              ExternalObject.new(arg, @ctrl_thread)
            end
          else
            Marshal.load(dumped)
          end
        end
      end
    end
    args.is_a?(Array) ? args.map(&pr) : pr.call(args)
  end

  def sanity_after_queue(args)
    pr = proc do |arg|
      case arg
      when InternalObject, ExternalObject
        arg.access_allowed? ? arg.object : arg
      else
        arg
      end
    end
    args.is_a?(Array) ? args.map(&pr) : pr.call(args)
  end

  Callback = Struct.new :args, :cbresult
  CallbackResult = Struct.new :res, :cbresult

  def process_input_queue
    call = @input_queue.deq
    case call
    when SyncCall
      res = self.send("__#{call.name}__", *sanity_after_queue(call.args))
      res = sanity_before_queue(res)
      call.answer_queue << res
    when YieldCall
      self.send("__#{call.name}__", *sanity_after_queue(call.args), proc do |*resu|
        resu = self.class.return_args(resu)
        resu = sanity_before_queue(resu)
        call.answer_queue << resu
      end) do |*cbargs, &cbresult|
        cbargs = sanity_after_queue(cbargs)
        call.answer_queue << Callback.new(cbargs, cbresult)
      end
    when AsyncCall
      self.send("__#{call.name}__", *sanity_after_queue(call.args))
    when CallbackResult
      cbres = sanity_after_queue(call.res)
      call.cbresult.yield(cbres)
    when ThreadFinished
      @threads.rm_action_thread(call.thread) or raise(ArgumentError, "unknown thread has finished")
    else
      raise ArgumentError, "invalid call type #{call.inspect}"
    end
  end
end
