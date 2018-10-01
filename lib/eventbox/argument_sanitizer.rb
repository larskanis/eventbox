class Eventbox
  # Mixin for argument sanitation.
  #
  # All call arguments are passed through as either copies or wrapped objects.
  # Certain object types are passed through unchanged.
  #
  # * If the object is mashalable, it is passed as a deep copy through Marshal.dump and Marshal.load .
  #   An object which faild to marshal is wrapped as {ExternalObject}.
  # * Proc objects passed from internal to external are wrapped as {InternalObject}.
  #   They are unwrapped when passed back to internal.
  # * Proc objects passed from external to internal are wrapped as {ExternalProc}.
  #   They are unwrapped when passed back to external.
  # * Proc objects created by {Eventbox#async_proc}, {Eventbox#sync_proc} and {Eventbox#yield_proc} are passed through without change.
  #
  # ArgumentSanitizer expects the method `event_loop' to return the related EventLoop instance.
  module ArgumentSanitizer
    private

    def return_args(args)
      args.length <= 1 ? args.first : args
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
            # Object not copyable -> wrap object as internal or external object
            sanity_before_queue2(mutable_object(arg), name)
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

    def mutable_object(object)
      if event_loop.internal_thread?
        ObjectRegistry.set_tag(object, event_loop)
      else
        ObjectRegistry.set_tag(object, :extern)
      end
      object
    end
  end

  class WrappedObject
    attr_reader :name
    def initialize(object, event_loop, name=nil)
      @object = object
      @event_loop = event_loop
      @name = name
    end
  end

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

  class WrappedProc < Proc
  end

  class InternalProc < WrappedProc
  end

  class AsyncProc < InternalProc
  end

  class SyncProc < InternalProc
  end

  class YieldProc < InternalProc
  end

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
