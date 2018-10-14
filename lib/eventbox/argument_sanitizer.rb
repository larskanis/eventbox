class Eventbox
  # Mixin for argument sanitation.
  #
  # All call arguments are passed through as either copies or wrapped objects.
  # Certain object types are passed through unchanged.
  #
  # Objects which are passed through unchanged are:
  # * Eventbox, Action and Module objects
  # * Proc objects created by {Eventbox#async_proc}, {Eventbox#sync_proc} and {Eventbox#yield_proc}
  #
  # If the object has been marked as {mutable_object}, it is wrapped as {InternalObject} or {ExternalObject}.
  # In all other cases the following rules apply:
  # * If the object is mashalable, it is passed as a deep copy through Marshal.dump and Marshal.load .
  # * An object which failed to marshal as a whole is tried to be dissected and values are sanitized recursively.
  # * If the object can't be marshaled or dissected, it is wrapped as {InternalObject} or {ExternalObject}.
  # * Proc objects passed from internal to external are wrapped as {InternalObject}.
  #   They are unwrapped when passed back to internal.
  # * Proc objects passed from external to internal are wrapped as {ExternalProc}.
  #   They are unwrapped when passed back to external.
  #
  # ArgumentSanitizer expects the method `event_loop' to return the related EventLoop instance.
  module ArgumentSanitizer
    private

    def return_args(args)
      args.length <= 1 ? args.first : args
    end

    def dissect_instance_variables(arg)
      # Separate the instance variables from the object
      ivns = arg.instance_variables
      ivvs = ivns.map do |ivn|
        arg.instance_variable_get(ivn)
      end

      # Temporary set all instance variables to nil
      ivns.each do |ivn|
        arg.instance_variable_set(ivn, nil)
      end

      # Copy the object
      arg2 = yield(arg)

      # Restore the original object
      ivns.each_with_index do |ivn, ivni|
        arg.instance_variable_set(ivn, ivvs[ivni])
      end

      # sanitize instance variables independently and write them to the copied object
      ivns.each_with_index do |ivn, ivni|
        ivv = sanity_before_queue2(ivvs[ivni], ivn)
        arg2.instance_variable_set(ivn, ivv)
      end

      arg2
    end

    def dissect_struct_members(arg)
      ms = arg.members
      vs = arg.values

      ms.each do |m|
        arg[m] = nil
      end

      arg2 = yield(arg)

      ms.each_with_index do |m, i|
        arg[m] = vs[i]
      end

      ms.each_with_index do |m, i|
        v2 = sanity_before_queue2(vs[i], m)
        arg2[m] = v2
      end

      arg2
    end

    def dissect_hash_values(arg)
      h = arg.dup

      h.each_key do |k|
        arg[k] = nil
      end

      arg2 = yield(arg)

      h.each do |k, v|
        arg[k] = v
      end

      h.each do |k, v|
        arg2[k] = sanity_before_queue2(v, k)
      end

      arg2
    end

    def dissect_array_values(arg, name)
      vs = arg.dup

      vs.each_index do |i|
        arg[i] = nil
      end

      arg2 = yield(arg)

      vs.each_index do |i|
        arg[i] = vs[i]
      end

      vs.each_with_index do |v, i|
        v2 = sanity_before_queue2(v, name)
        arg2[i] = v2
      end

      arg2
    end

    def sanity_before_queue2(arg, name)
      case arg
      when WrappedObject, WrappedProc, Action # If object is already wrapped -> pass it through
        arg
      when Module # Class or Module definitions are passed through
        arg
      when Eventbox # Eventbox objects already sanitize all inputs and outputs and are thread safe
        arg
      when Proc
        event_loop.wrap_proc(arg, name)
      else
        # Check if the object has been tagged
        case ObjectRegistry.get_tag(arg)
        when EventLoop
          InternalObject.new(arg, event_loop, name)
        when :extern
          ExternalObject.new(arg, event_loop, name)
        else
          # Not tagged -> try to deep copy the object
          begin
            dumped = Marshal.dump(arg)
          rescue TypeError

            # Try to separate internal data from the object to sanitize it independently
            begin
              case arg
              when Array
                dissect_array_values(arg, name) do |arg2|
                  dissect_instance_variables(arg2) do |arg3|
                    Marshal.load(Marshal.dump(arg3))
                  end
                end

              when Hash
                dissect_hash_values(arg) do |arg2|
                  dissect_instance_variables(arg2) do |arg3|
                    Marshal.load(Marshal.dump(arg3))
                  end
                end

              when Struct
                dissect_struct_members(arg) do |arg2|
                  dissect_instance_variables(arg2) do |arg3|
                    Marshal.load(Marshal.dump(arg3))
                  end
                end

              else
                dissect_instance_variables(arg) do |empty_arg|
                  # Retry to dump the now empty object
                  Marshal.load(Marshal.dump(empty_arg))
                end
              end
            rescue TypeError
              # Object not copyable -> wrap object as internal or external object
              sanity_before_queue2(mutable_object(arg), name)
            end

          else
            Marshal.load(dumped)
          end
        end
      end
    end

    def sanity_before_queue(args, name=nil)
      args.is_a?(Array) ? args.map { |arg| sanity_before_queue2(arg, name) } : sanity_before_queue2(args, name)
    end

    def sanity_after_queue2(arg, current_thread=Thread.current)
      case arg
      when WrappedObject
        arg.access_allowed?(current_thread) ? arg.object : arg
      when ExternalProc
        arg.direct_callable?(current_thread) ? arg.object : arg
      else
        arg
      end
    end

    def sanity_after_queue(args, current_thread=Thread.current)
      args.is_a?(Array) ? args.map { |arg| sanity_after_queue2(arg, current_thread) } : sanity_after_queue2(args, current_thread)
    end

    def callback_loop(answer_queue)
      loop do
        rets = answer_queue.deq
        case rets
        when EventLoop::Callback
          args = sanity_after_queue(rets.args)
          cbres = sanity_after_queue(rets.block).yield(*args)

          if rets.cbresult
            cbres = sanity_before_queue(cbres)
            event_loop.external_proc_result(rets.cbresult, cbres)
          end
        else
          answer_queue.close if answer_queue.respond_to?(:close)
          return sanity_after_queue(rets)
        end
      end
    end

    public

    # Mark a mutable object as to be wrapped as {InternalObject} or {ExternalObject} instead of being copied.
    #
    # The mark is stored for the lifetime of the object, so that it's enough to mark only once at object creation.
    #
    # A marked object is not passed by copy, but passed by reference.
    # Wrapping as {InternalObject} or {ExternalObject} denies external access to internal objects and vice versa.
    # However the object is passed as reference and unwrapped when passed back to the original scope.
    # It can therefore be used to modify the original object even after traversing the boundary.
    def mutable_object(object)
      if event_loop.internal_thread?
        ObjectRegistry.set_tag(object, event_loop)
      else
        ObjectRegistry.set_tag(object, :extern)
      end
      object
    end
  end

  # Base wrapper class for objects created internal or external.
  class WrappedObject
    attr_reader :name
    def initialize(object, event_loop, name=nil)
      @object = object
      @event_loop = event_loop
      @name = name
    end
  end

  # Generic wrapper for objects created internal within some Eventbox instance.
  #
  # Access to the internal object from outside of the event loop is denied, but the wrapper object can be stored and passed back to internal to unwrap it.
  class InternalObject < WrappedObject
    def access_allowed?(current_thread=Thread.current)
      @event_loop.internal_thread?(current_thread)
    end

    def object
      raise InvalidAccess, "access to internal object #{@object.inspect} #{"wrapped by #{name} " if name}not allowed outside of the event loop" unless access_allowed?
      @object
    end
  end

  # Generic wrapper for objects created external of some Eventbox instance.
  #
  # Access to the external object from the event loop is denied, but the wrapper object can be stored and passed back to external (or passed to actions) to unwrap it.
  class ExternalObject < WrappedObject
    def access_allowed?(current_thread=Thread.current)
      !@event_loop.internal_thread?(current_thread)
    end

    def object
      raise InvalidAccess, "access to external object #{@object.inspect} #{"wrapped by #{name} " if name}not allowed in the event loop" unless access_allowed?
      @object
    end
  end

  # Base class for Proc objects created internal or external.
  class WrappedProc < Proc
  end

  # Base class for Proc objects created internal within some Eventbox instance.
  class InternalProc < WrappedProc
  end

  # Proc objects created intern within some Eventbox instance per {Eventbox#async_proc}
  class AsyncProc < InternalProc
  end

  # Proc objects created intern within some Eventbox instance per {Eventbox#sync_proc}
  class SyncProc < InternalProc
  end

  # Proc objects created intern within some Eventbox instance per {Eventbox#yield_proc}
  class YieldProc < InternalProc
  end

  # Wrapper for Proc objects created external of some Eventbox instance.
  #
  # External Proc objects can not be called from internal methods.
  # Instead they can be passed through to actions or to extern to be called there.
  # In this case a {ExternalProc} is unwrapped back to an ordinary Proc object.
  class ExternalProc < WrappedProc
    attr_reader :name
    def initialize(object, event_loop, name=nil)
      @object = object
      @event_loop = event_loop
      @name = name
    end

    def direct_callable?(current_thread=Thread.current)
      !@event_loop.internal_thread?(current_thread)
    end

    def object
      raise InvalidAccess, "access to external proc #{@object.inspect} #{"wrapped by #{name} " if name}not allowed in the event loop" unless direct_callable?
      @object
    end
  end
end
