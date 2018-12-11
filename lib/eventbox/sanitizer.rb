# frozen-string-literal: true

class Eventbox
  # Module for argument and result value sanitation.
  #
  # All call arguments and result values between external and event scope an vice versa are passed through the Sanitizer.
  # This filter is required to prevent data races through shared objects or non-synchonized proc execution.
  # It also wraps blocks and Proc objects to arbitrate between external blocking behaviour and internal event based behaviour.
  #
  # Depending on the type of the object and the direction of the call it is passed
  # * directly (immutable object types or already wrapped objects)
  # * as a deep copy (if copyable)
  # * as a safely callable wrapped object (Proc objects)
  # * as a non-callable wrapped object (non copyable objects)
  # * as an unwrapped object (when passing a wrapped object back to origin scope)
  #
  # The filter is recursively applied to all object data (instance variables or elements), if the object is non copyable.
  #
  # In detail this works as following.
  # Objects which are passed through unchanged are:
  # * {Eventbox}, {Eventbox::Action} and `Module` objects
  # * Proc objects created by {Eventbox#async_proc}, {Eventbox#sync_proc} and {Eventbox#yield_proc}
  #
  # The following rules apply for wrapping/unwrapping:
  # * If the object has been marked as {Eventbox#shared_object}, it is wrapped as {WrappedObject} or {ExternalObject} depending on the direction of the data flow (return value or call argument).
  # * If the object is a {WrappedObject} or {ExternalProc} and fits to the target scope, it is unwrapped.
  # Both cases even work if the object is encapsulated by another object.
  #
  # In all other cases the following rules apply:
  # * If the object is marshalable, it is passed as a deep copy through `Marshal.dump` and `Marshal.load` .
  # * An object which failed to marshal as a whole is tried to be dissected and values are sanitized recursively.
  # * If the object can't be marshaled or dissected, it is wrapped as {ExternalObject} when passed from external scope to event scope and wrapped as {WrappedObject} when passed from the event scope.
  #   They are unwrapped when passed back to origin scope.
  # * Proc objects passed from event scope to external are wrapped as {WrappedObject}.
  #   They are unwrapped when passed back to event scope.
  # * Proc objects passed from external to event scope are wrapped as {ExternalProc}.
  #   They are unwrapped when passed back to external scope.
  module Sanitizer
    module_function

    def return_args(args)
      args.length <= 1 ? args.first : args
    end

    def dissect_instance_variables(arg, source_event_loop, target_event_loop)
      # Separate the instance variables from the object
      ivns = arg.instance_variables
      ivvs = ivns.map do |ivn|
        ivv = arg.instance_variable_get(ivn)
        # Temporary set all instance variables to nil
        arg.instance_variable_set(ivn, nil)
        ivv
      end

      # Copy the object
      arg2 = yield(arg)
    rescue
      # Restore the original object in case of Marshal.dump failure
      ivns.each_with_index do |ivn, ivni|
        arg.instance_variable_set(ivn, ivvs[ivni])
      end
      raise
    else
      ivns.each_with_index do |ivn, ivni|
        # Restore the original object
        arg.instance_variable_set(ivn, ivvs[ivni])
        # sanitize instance variables independently and write them to the copied object
        ivv = sanitize_value(ivvs[ivni], source_event_loop, target_event_loop, ivn)
        arg2.instance_variable_set(ivn, ivv)
      end

      arg2
    end

    def dissect_struct_members(arg, source_event_loop, target_event_loop)
      ms = arg.members
      # call Array#map on Struct#values to work around bug JRuby bug https://github.com/jruby/jruby/issues/5372
      vs = arg.values.map{|a| a }

      ms.each do |m|
        arg[m] = nil
      end

      arg2 = yield(arg)
    rescue
      # Restore the original object in case of Marshal.dump failure
      ms.each_with_index do |m, i|
        arg[m] = vs[i]
      end
      raise
    else
      ms.each_with_index do |m, i|
        arg[m] = vs[i]
        v2 = sanitize_value(vs[i], source_event_loop, target_event_loop, m)
        arg2[m] = v2
      end

      arg2
    end

    def dissect_hash_values(arg, source_event_loop, target_event_loop)
      h = arg.dup

      h.each_key do |k|
        arg[k] = nil
      end

      arg2 = yield(arg)
    rescue
      # Restore the original object in case of Marshal.dump failure
      h.each do |k, v|
        arg[k] = v
      end
      raise
    else
      h.each do |k, v|
        arg[k] = v
        arg2[k] = sanitize_value(v, source_event_loop, target_event_loop, k)
      end

      arg2
    end

    def dissect_array_values(arg, source_event_loop, target_event_loop, name)
      vs = arg.dup

      vs.each_index do |i|
        arg[i] = nil
      end

      arg2 = yield(arg)
    rescue
      # Restore the original object in case of Marshal.dump failure
      vs.each_with_index do |v, i|
        arg[i] = vs[i]
      end
      raise
    else
      vs.each_with_index do |v, i|
        arg[i] = vs[i]
        v2 = sanitize_value(v, source_event_loop, target_event_loop, name)
        arg2[i] = v2
      end

      arg2
    end

    def sanitize_value(arg, source_event_loop, target_event_loop, name=nil)
      case arg
      when NilClass, Numeric, Symbol, TrueClass, FalseClass # Immutable objects
        arg
      when WrappedObject
        arg.object_for(target_event_loop)
      when ExternalProc
        arg.object_for(target_event_loop)
      when InternalProc, Action # If object is already wrapped -> pass it through
        arg
      when Module # Class or Module definitions are passed through
        arg
      when Eventbox # Eventbox objects already sanitize all inputs and outputs and are thread safe
        arg
      when Proc
        wrap_proc(arg, name, source_event_loop, target_event_loop)
      else
        # Check if the object has been tagged
        case mel=ObjectRegistry.get_tag(arg)
        when EventLoop # Event scope object marked as shared_object
          unless mel == source_event_loop
            raise InvalidAccess, "object #{arg.inspect} #{"wrapped by #{name} " if name} was marked as shared_object in a different eventbox object than the calling eventbox"
          end
          wrap_object(arg, mel, target_event_loop, name)
        when ExternalSharedObject # External object marked as shared_object
          wrap_object(arg, source_event_loop, target_event_loop, name)
        else
          # Not tagged -> try to deep copy the object
          begin
            dumped = Marshal.dump(arg)
          rescue TypeError

            # Try to separate internal data from the object to sanitize it independently
            begin
              case arg
              when Array
                dissect_array_values(arg, source_event_loop, target_event_loop, name) do |arg2|
                  dissect_instance_variables(arg2, source_event_loop, target_event_loop) do |arg3|
                    Marshal.load(Marshal.dump(arg3))
                  end
                end

              when Hash
                dissect_hash_values(arg, source_event_loop, target_event_loop) do |arg2|
                  dissect_instance_variables(arg2, source_event_loop, target_event_loop) do |arg3|
                    Marshal.load(Marshal.dump(arg3))
                  end
                end

              when Struct
                dissect_struct_members(arg, source_event_loop, target_event_loop) do |arg2|
                  dissect_instance_variables(arg2, source_event_loop, target_event_loop) do |arg3|
                    Marshal.load(Marshal.dump(arg3))
                  end
                end

              else
                dissect_instance_variables(arg, source_event_loop, target_event_loop) do |empty_arg|
                  # Retry to dump the now empty object
                  Marshal.load(Marshal.dump(empty_arg))
                end
              end
            rescue TypeError
              if source_event_loop
                ObjectRegistry.set_tag(arg, source_event_loop)
              else
                ObjectRegistry.set_tag(arg, ExternalSharedObject)
              end

              # Object not copyable -> wrap object as event scope or external object
              sanitize_value(arg, source_event_loop, target_event_loop, name)
            end

          else
            Marshal.load(dumped)
          end
        end
      end
    end

    def sanitize_values(args, source_event_loop, target_event_loop, name=nil)
      args.map { |arg| sanitize_value(arg, source_event_loop, target_event_loop, name) }
    end

    def wrap_proc(arg, name, source_event_loop, target_event_loop)
      if target_event_loop&.event_scope?
        creation_answer_queue = target_event_loop.latest_answer_queue
        ExternalProc.new(arg, source_event_loop, name) do |*args, &block|
          if target_event_loop&.event_scope?
            # called in the event scope
            if block && !(WrappedProc === block)
              raise InvalidAccess, "calling #{arg.inspect} with block argument #{block.inspect} is not allowed - use async_proc, sync_proc, yield_proc or an external proc instead"
            end
            cbblock = args.pop if Proc === args.last
            target_event_loop._external_object_call(arg, :call, name, args, block, cbblock, source_event_loop, creation_answer_queue)
          else
            # called externally
            raise InvalidAccess, "external proc #{arg.inspect} #{"wrapped by #{name} " if name} can not be called in a different eventbox instance"
          end
        end
      else
        WrappedObject.new(arg, source_event_loop, name)
      end
    end

    def wrap_object(object, source_event_loop, target_event_loop, name)
      if target_event_loop&.event_scope?
        creation_answer_queue = target_event_loop.latest_answer_queue
        ExternalObject.new(object, source_event_loop, target_event_loop, creation_answer_queue, name)
      else
        WrappedObject.new(object, source_event_loop, name)
      end
    end
  end

  # Generic wrapper for objects that are passed through a foreign scope as reference.
  #
  # Access to the object from a different scope is denied, but the wrapper object can be stored and passed back to the origin scope to unwrap it.
  class WrappedObject
    attr_reader :name
    # @private
    def initialize(object, event_loop, name=nil)
      @object = object
      @event_loop = event_loop
      @name = name
      @dont_marshal = ExternalSharedObject # protect self from being marshaled
    end

    # @private
    def object_for(target_event_loop)
      @event_loop == target_event_loop ? @object : self
    end

    def inspect
      "#<#{self.class} @object=#{@object.inspect} @name=#{@name.inspect}>"
    end
  end

  # Wrapper for objects created external or in the action scope of some Eventbox instance.
  #
  # External objects can be called from event scope by {ExternalObject#send_async}.
  #
  # External objects can also be passed to action or to external scope.
  # In this case a {ExternalObject} is unwrapped back to the ordinary object.
  #
  # @see ExternalProc
  class ExternalObject < WrappedObject
    # @private
    def initialize(object, event_loop, target_event_loop, creation_answer_queue, name=nil)
      super(object, event_loop, name)
      @target_event_loop = target_event_loop
      @creation_answer_queue = creation_answer_queue
    end

    # Invoke the external objects within the event scope.
    #
    # It can be called within {Eventbox::Boxable#sync_call sync_call} and {Eventbox::Boxable#yield_call yield_call} methods and from {Eventbox#sync_proc} and {Eventbox#yield_proc} closures.
    # The method then runs in the background on the thread that called the event scope method in execution.
    #
    # It's also possible to invoke it within a {Eventbox::Boxable#async_call async_call} or {Eventbox#async_proc}, when the method or proc that brought the external object into the event scope, is a yield call that didn't return yet.
    # In this case the method runs in the background on the thread that is waiting for the yield call to return.
    #
    # If the call to the external object doesn't return immediately, it blocks the calling thread.
    # If this is not desired, an {Eventbox::Boxable#action action} can be used instead, to invoke the method.
    # However in any case calling the external object doesn't block the Eventbox instance itself.
    # It still keeps responsive to calls from other threads.
    #
    # Optionally a proc can be provided as the last argument which acts as a completion callback.
    # This proc is invoked, when the call has finished, with the result value as argument.
    #
    #   class Sender < Eventbox
    #     sync_call def init(€obj)  # €-variables are passed as reference instead of copy
    #       # invoke the object given to Sender.new
    #       # and when completed, print the result of strip
    #       €obj.send_async :strip, ->(res){ p res }
    #     end
    #   end
    #   Sender.new(" a b c ")    # Output: "a b c"
    def send_async(method, *args, &block)
      if @target_event_loop&.event_scope?
        # called in the event scope
        if block && !(WrappedProc === block)
          raise InvalidAccess, "calling `#{method}' with block argument #{block.inspect} is not allowed - use async_proc, sync_proc, yield_proc or an external proc instead"
        end
        cbblock = args.pop if Proc === args.last
        @target_event_loop._external_object_call(@object, method, @name, args, block, cbblock, @event_loop, @creation_answer_queue)
      else
        # called externally
        raise InvalidAccess, "external object #{self.inspect} #{"wrapped by #{name} " if name} can not be called in a different eventbox instance"
      end
    end
  end

  # Base class for Proc objects created in any scope.
  class WrappedProc < Proc
  end

  # Base class for Proc objects created in the event scope of some Eventbox instance.
  class InternalProc < WrappedProc
  end

  # Proc objects created in the event scope of some Eventbox instance per {Eventbox#async_proc}
  class AsyncProc < InternalProc
  end

  # Proc objects created in the event scope of some Eventbox instance per {Eventbox#sync_proc}
  class SyncProc < InternalProc
  end

  # Proc objects created in the event scope of some Eventbox instance per {Eventbox#yield_proc}
  class YieldProc < InternalProc
  end

  WrappedException = Struct.new(:exc)

  # Proc object provided as the last argument of {Eventbox::Boxable#yield_call yield_call} and {Eventbox#yield_proc}.
  #
  # Used to let the corresponding yield call return a value:
  #   class MyBox < Eventbox
  #     yield_call def number(result)
  #       result.yield 42
  #     end
  #   end
  #   MyBox.new.number   # => 42
  #
  # Alternatively the yield call can respond with an exception by {CompletionProc#raise}.
  class CompletionProc < AsyncProc
    # Raise an exception in the context of the waiting {Eventbox::Boxable#yield_call yield_call} or {Eventbox#yield_proc} method.
    #
    # This allows to raise an exception to the calling scope from external or action scope:
    #
    #   class MyBox < Eventbox
    #     yield_call def init(result)
    #       process(result)
    #     end
    #
    #     action def process(result)
    #       result.raise RuntimeError, "raise from action MyBox#process"
    #     end
    #   end
    #   MyBox.new   # => raises RuntimeError (raise from action MyBox#process)
    #
    # In contrast to a direct call of `Kernel.raise`, calling this method doesn't abort the current context.
    # Instead when in the event scope, raising the exception is deferred until returning to the calling external or action scope.
    def raise(*args)
      self.call(WrappedException.new(args))
    end
  end

  # Wrapper for Proc objects created external or in the action scope of some Eventbox instance.
  #
  # External Proc objects can be invoked from event scope by {ExternalProc#call_async}.
  # It can be called within {Eventbox::Boxable#sync_call sync_call} and {Eventbox::Boxable#yield_call yield_call} methods and from {Eventbox#sync_proc} and {Eventbox#yield_proc} closures.
  # The proc then runs in the background on the thread that called the event scope method in execution.
  #
  # It's also possible to invoke it within a {Eventbox::Boxable#async_call async_call} or {Eventbox#async_proc}, when the method or proc that brought the external proc into the event scope, is a yield call that didn't return yet.
  # In this case the proc runs in the background on the thread that is waiting for the yield call to return.
  #
  # Optionally a proc can be provided as the last argument which acts as a completion callback.
  # This proc is invoked, when the call has finished, with the result value as argument.
  #
  #   class Callback < Eventbox
  #     sync_call def init(&block)
  #       # invoke the block given to Callback.new
  #       # and when completed, print the result of the block
  #       block.call_async 5, ->(res){ p res }
  #     end
  #   end
  #   Callback.new {|num| num + 1 }    # Output: 6
  #
  # External Proc objects can also be passed to action or to external scope.
  # In this case a {ExternalProc} is unwrapped back to the ordinary Proc object.
  #
  # @see ExternalObject
  class ExternalProc < WrappedProc
    # @private
    attr_reader :name
    # @private
    def initialize(object, event_loop, name=nil)
      @object = object
      @event_loop = event_loop
      @name = name
    end

    # @private
    def object_for(target_event_loop)
      @event_loop == target_event_loop ? @object : self
    end

    alias call_async call
    alias yield_async yield

    # @private
    def self.deprectate(name, repl)
      define_method(name) do |*args, &block|
        warn "#{caller[0]}: please use `#{repl}' instead of `#{name}' to call external procs"
        send(repl, *args, &block)
      end
    end
    deprectate :call, :call_async
    deprectate :yield, :yield_async
  end

  # @private
  ExternalSharedObject = IO.pipe.first
end
