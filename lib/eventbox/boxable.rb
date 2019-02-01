# frozen-string-literal: true

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
    private

    # @private
    def with_block_or_def(name, block, &cexec)
      alias_method("__#{name}__", name)
      private("__#{name}__")
      remove_method(name)
      define_method(name, &cexec)
      private name if name == :init
      name
    end

    # Define a threadsafe method for asynchronous (fire-and-forget) calls.
    #
    # The created method can be safely called from any thread.
    # All method arguments are passed through the {Sanitizer}.
    # Arguments prefixed by a +€+ sign are automatically passed as {Eventbox::ExternalObject}.
    #
    # The method itself might not do any blocking calls or expensive computations - this would impair responsiveness of the {Eventbox} instance.
    # Instead use {action} in these cases.
    #
    # In contrast to {sync_call} it's not possible to call external blocks or proc objects from {async_call} methods.
    #
    # The method always returns +self+ to the caller.
    def async_call(name, &block)
      unbound_method = self.instance_method(name)
      wrapper = ArgumentWrapper.build(unbound_method, name)
      with_block_or_def(name, block) do |*args, &cb|
        if @__event_loop__.event_scope?
          # Use the correct method within the class hierarchy, instead of just self.send(*args).
          # Otherwise super() would start an infinite recursion.
          unbound_method.bind(eventbox).call(*args, &cb)
        else
          @__event_loop__.async_call(eventbox, name, args, cb, wrapper)
        end
        self
      end
    end

    # Define a method for synchronous calls.
    #
    # The created method can be safely called from any thread.
    # It is simular to {async_call}, but the method waits until the method body is executed and returns its return value.
    # Since all processing within the event scope of an {Eventbox} instance must not involve blocking operations, sync calls can only return immediate values.
    # For deferred results use {yield_call} instead.
    #
    # It's possible to call external blocks or proc objects from {sync_call} methods.
    # Blocks are executed by the same thread that calls the {sync_call} method to that time.
    #
    # All method arguments as well as the result value are passed through the {Sanitizer}.
    # Arguments prefixed by a +€+ sign are automatically passed as {Eventbox::ExternalObject}.
    #
    # The method itself might not do any blocking calls or expensive computations - this would impair responsiveness of the {Eventbox} instance.
    # Instead use {action} in these cases.
    def sync_call(name, &block)
      unbound_method = self.instance_method(name)
      wrapper = ArgumentWrapper.build(unbound_method, name)
      with_block_or_def(name, block) do |*args, &cb|
        if @__event_loop__.event_scope?
          unbound_method.bind(eventbox).call(*args, &cb)
        else
          answer_queue = Queue.new
          sel = @__event_loop__.sync_call(eventbox, name, args, cb, answer_queue, wrapper)
          @__event_loop__.callback_loop(answer_queue, sel, name)
        end
      end
    end

    # Define a method for calls with deferred result.
    #
    # This call type is simular to {sync_call}, however it's not the result of the method that is returned.
    # Instead the method is called with one {CompletionProc additional argument} in the event scope, which is used to yield a result value or raise an exception.
    # In contrast to a +return+ statement, the execution of the method continues after yielding a result.
    #
    # The result value can be yielded within the called method, but it can also be stored and called by any other event scope or external method, leading to a deferred method return.
    # The external thread calling this method is suspended until a result is yielded.
    # However the Eventbox object keeps responsive to calls from other threads.
    #
    # The created method can be safely called from any thread.
    # If yield methods are called in the event scope, they must get a Proc object as the last argument.
    # It is called when a result was yielded.
    #
    # It's possible to call external blocks or proc objects from {yield_call} methods up to the point when the result was yielded.
    # Blocks are executed by the same thread that calls the {yield_call} method to that time.
    #
    # All method arguments as well as the result value are passed through the {Sanitizer}.
    # Arguments prefixed by a +€+ sign are automatically passed as {Eventbox::ExternalObject}.
    #
    # The method itself as well as the Proc object might not do any blocking calls or expensive computations - this would impair responsiveness of the {Eventbox} instance.
    # Instead use {action} in these cases.
    def yield_call(name, &block)
      unbound_method = self.instance_method(name)
      wrapper = ArgumentWrapper.build(unbound_method, name)
      with_block_or_def(name, block) do |*args, **kwargs, &cb|
        if @__event_loop__.event_scope?
          @__event_loop__.internal_yield_result(args, name)
          args << kwargs unless kwargs.empty?
          unbound_method.bind(eventbox).call(*args, &cb)
          self
        else
          answer_queue = Queue.new
          sel = @__event_loop__.yield_call(eventbox, name, args, kwargs, cb, answer_queue, wrapper)
          @__event_loop__.callback_loop(answer_queue, sel, name)
        end
      end
    end

    # Threadsafe write access to instance variables.
    def attr_writer(*names)
      super
      names.each do |name|
        async_call(:"#{name}=")
      end
    end

    # Threadsafe read access to instance variables.
    def attr_reader(*names)
      super
      names.each do |name|
        sync_call(:"#{name}")
      end
    end

    # Threadsafe read and write access to instance variables.
    #
    # Attention: Be careful with read-modify-write operations like "+=" - they are *not* atomic but are executed as two independent operations.
    #
    # This will lose counter increments, since +counter+ is incremented in a non-atomic manner:
    #   attr_accessor :counter
    #   async_call def start
    #     10.times { do_something }
    #   end
    #   action def do_something
    #     self.counter += 1
    #   end
    #
    # Instead don't use accessors but do increments within one method call like so:
    #   async_call def start
    #     10.times { do_something }
    #   end
    #   action def do_something
    #     increment 1
    #   end
    #   async_call def increment(by)
    #     @counter += by
    #   end
    def attr_accessor(*names)
      super
      names.each do |name|
        async_call(:"#{name}=")
        sync_call(:"#{name}")
      end
    end

    # Define a private method for asynchronous execution.
    #
    # The call to the action method returns immediately after starting a new action.
    # It returns an {Action} object.
    # By default each call to an action method spawns a new thread which executes the code of the action definition.
    # Alternatively a threadpool can be assigned by {with_options}.
    #
    # All method arguments are passed through the {Sanitizer}.
    #
    # Actions can return state changes or objects to the event loop by calls to methods created by {async_call}, {sync_call} or {yield_call} or through calling {async_proc}, {sync_proc} or {yield_proc} objects.
    # To avoid unsafe shared objects, an action has it's own set of local variables or instance variables.
    # It doesn't have access to variables defined by other methods.
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
    #     # `action' can be passed to event scope or external scope,
    #     # in order to send a signal per Action#raise
    #   end
    #
    def action(name, &block)
      unbound_method = self.instance_method(name)
      with_block_or_def(name, block) do |*args, &cb|
        raise InvalidAccess, "action must not be called with a block" if cb

        gc_actions = self.class.eventbox_options[:gc_actions]
        sandbox = self.class.allocate
        sandbox.instance_variable_set(:@__event_loop__, @__event_loop__)
        sandbox.instance_variable_set(:@__eventbox__, gc_actions ? WeakRef.new(self) : self)
        meth = unbound_method.bind(sandbox)

        if @__event_loop__.event_scope?
          args = Sanitizer.sanitize_values(args, @__event_loop__, nil)
        end
        # Start a new action thread and return an Action instance
        @__event_loop__.start_action(meth, name, args)
      end
      private name
      name
    end
  end

  # An Action object is thin wrapper for a Ruby thread.
  #
  # It is returned by {Eventbox::Boxable#action action methods} and optionally passed as last argument to action methods.
  # It can be used to interrupt the program execution by an exception.
  #
  # However in contrast to ruby's builtin threads, any interruption must be explicit allowed.
  # Exceptions raised to an action thread are delayed until a code block is reached which explicit allows interruption.
  # The only exception which is delivered to the action thread by default is {Eventbox::AbortAction}.
  # It is raised by {Eventbox#shutdown!} and is delivered as soon as a blocking operation is executed.
  #
  # An Action object can be used to stop the action while blocking operations.
  # It should be made sure, that the +rescue+ statement is outside of the block to +handle_interrupt+.
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
    #
    # If {raise} is called within the action ({#current?} returns +true+), all exceptions are delivered immediately.
    # This happens regardless of the current interrupt mask set by +Thread.handle_interrupt+.
    def raise(*args)
      # ignore raise, if sent from the action thread
      if AbortAction === args[0] || (Module === args[0] && args[0].ancestors.include?(AbortAction))
        ::Kernel.raise InvalidAccess, "Use of Eventbox::AbortAction is not allowed - use Action#abort or a custom exception subclass"
      end

      if @event_loop.event_scope?
        args = Sanitizer.sanitize_values(args, @event_loop, nil)
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

    # @private
    def join
      @thread.join
    end
  end
end
