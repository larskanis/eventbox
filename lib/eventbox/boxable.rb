class Eventbox

  # Extend modules with Eventbox method creation functions
  #
  # This works like so:
  #
  #   module MyHelpers
  #     extend Eventbox::Boxable
  #     sync_call def hello
  #       puts "hello!"
  #     end
  #   end
  #
  #   class MyBox < Eventbox
  #     include MyHelpers
  #   end
  #
  #   MyBox.new.hello   # prints "hello!"
  #
  module Boxable
    private def with_block_or_def(name, block, &cexec)
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
    # All method arguments are passed through the {ArgumentSanitizer}.
    # The method itself might not do any blocking calls or extensive computations - this would impair responsiveness of the {Eventbox} instance.
    # Instead use {Eventbox.action Eventbox.action} in these cases.
    #
    # The method always returns +self+ to the caller.
    def async_call(name, &block)
      unbound_method = nil
      with_block_or_def(name, block) do |*args, &cb|
        if @event_loop.internal_thread?
          # Use the correct method within the class hierarchy, instead of just self.send(*args).
          # Otherwise super() would start an infinite recursion.
          unbound_method.bind(eventbox).call(*args) do |*cbargs|
            cb.yield(*cbargs)
          end
        else
          args = ArgumentSanitizer.sanitize_values(args, @event_loop, @event_loop, name)
          cb = ArgumentSanitizer.sanitize_values(cb, @event_loop, @event_loop, name)
          @event_loop.async_call(eventbox, name, args, cb)
        end
        self
      end
      unbound_method = self.instance_method("__#{name}__")
      name
    end

    # Define a method for synchronous calls.
    #
    # The created method can be safely called from any thread.
    # It is simular to {async_call}, but the method waits until the method body is executed and returns its return value.
    # Since all internal processing within a {Eventbox} instance must not involve blocking operations, sync calls can only return immediate values.
    # For deferred results use {yield_call} instead.
    #
    # All method arguments as well as the result value are passed through the {ArgumentSanitizer}.
    def sync_call(name, &block)
      unbound_method = nil
      with_block_or_def(name, block) do |*args, &cb|
        if @event_loop.internal_thread?
          unbound_method.bind(eventbox).call(*args) do |*cbargs|
            cb.yield(*cbargs)
          end
        else
          args = ArgumentSanitizer.sanitize_values(args, @event_loop, @event_loop, name)
          cb = ArgumentSanitizer.sanitize_values(cb, @event_loop, @event_loop, name)
          answer_queue = Queue.new
          @event_loop.sync_call(eventbox, name, args, answer_queue, cb)
          @event_loop.callback_loop(answer_queue)
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
    # This call type is simular to {sync_call}, however it's not the result of the method that is returned.
    # Instead the method is called with one additional argument internally, which is used to yield a result value.
    # The result value can be yielded within the called method, but it can also be called by any other internal or external method, leading to a deferred method return.
    # The external thread calling this method is suspended until a result is yielded.
    #
    # All method arguments as well as the result value are passed through the {ArgumentSanitizer}.
    def yield_call(name, &block)
      with_block_or_def(name, block) do |*args, &cb|
        if @event_loop.internal_thread?
          raise InvalidAccess, "yield_call `#{name}' can not be called internally - use sync_call or async_call instead"
        else
          args = ArgumentSanitizer.sanitize_values(args, @event_loop, @event_loop, name)
          cb = ArgumentSanitizer.sanitize_values(cb, @event_loop, @event_loop, name)
          answer_queue = Queue.new
          @event_loop.yield_call(eventbox, name, args, answer_queue, cb)
          @event_loop.callback_loop(answer_queue)
        end
      end
      name
    end

    # Threadsafe write access to instance variables.
    def attr_writer(name)
      async_call("#{name}=") do |value|
        instance_variable_set("@#{name}", value)
      end
    end

    # Threadsafe read access to instance variables.
    def attr_reader(name)
      sync_call("#{name}") do
        instance_variable_get("@#{name}")
      end
    end

    # Threadsafe read and write access to instance variables.
    #
    # Attention: Be careful with read-modify-write operations - they are *not* atomic!
    #
    # This will lose counter increments, since `counter` is incremented in a non-atomic manner:
    #   attr_accessor :counter
    #   async_call def start
    #     10.times { do_something }
    #   end
    #   action def do_something
    #     self.counter += 1
    #   end
    #
    # Instead do increments within one method call like so:
    #   action def do_something
    #     increment 1
    #   end
    #   async_call def increment(by)
    #     @counter += by
    #   end
    def attr_accessor(name)
      attr_reader name
      attr_writer name
    end

    # Define a method for asynchronous execution.
    #
    # The call to the action method returns immediately after starting a new action.
    # It returns an {Action} object.
    # By default each call to an action method spawns a new thread which executes the code of the action definition.
    # Alternatively a threadpool can be assigned by {with_options}.
    #
    # All method arguments are passed through the {ArgumentSanitizer}.
    #
    # Actions can return state changes or objects to the event loop by calls to methods created by {async_call}, {sync_call} or {yield_call} or through calling {async_proc}, {sync_proc} or {yield_proc} objects.
    # To avoid unsafe shared objects, the action block doesn't have access to local variables or instance variables.
    #
    # The {Action} object can be used to interrupt the program execution by an exception.
    # See {Eventbox::Action} for further information.
    # If the action method accepts one more argument than given to the action call, it is set to corresponding {Action} instance:
    #   async_call def init
    #     do_something("value1")
    #   end
    #   action def do_something(str, action)
    #     str              # => "value1"
    #     action.current?  # => true
    #     # `action' can be passed to some internal or external method,
    #     # to send a signal per Action#raise
    #   end
    #
    def action(name, &block)
      unbound_method = nil
      with_block_or_def(name, block) do |*args, &cb|
        raise InvalidAccess, "action must be called from the event loop thread" unless @event_loop.internal_thread?

        sandbox = self.class.allocate
        sandbox.instance_variable_set(:@event_loop, @event_loop)
        sandbox.instance_variable_set(:@eventbox, WeakRef.new(self))
        meth = unbound_method.bind(sandbox)

        args = ArgumentSanitizer.sanitize_values(args, @event_loop, :extern)
        # Start a new action thread and return an Action instance
        @event_loop._start_action(meth, name, args)
      end
      unbound_method = self.instance_method("__#{name}__")
      name
    end
  end
end
