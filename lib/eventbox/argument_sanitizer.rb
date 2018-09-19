class Eventbox
  class InternalObject < Object
    def initialize(object, event_loop)
      @object = object
      @event_loop = event_loop
    end

    def access_allowed?
      @event_loop.internal_thread?
    end

    def object
      raise InvalidAccess, "access to internal object #{@object.inspect} not allowed outside of the event loop" unless access_allowed?
      @object
    end
  end

  class ExternalObject < Object
    def initialize(object, event_loop)
      @object = object
      @event_loop = event_loop
    end

    def access_allowed?
      !@event_loop.internal_thread?
    end

    def object
      raise InvalidAccess, "access to external object #{@object.inspect} not allowed in the event loop" unless access_allowed?
      @object
    end
  end

  module ArgumentSanitizer
    private

    def return_args(args)
      args.length <= 1 ? args.first : args
    end

    def sanity_before_queue2(arg)
      case arg
      # If object is already wrapped -> pass through
      when InternalObject, ExternalObject
        arg
      else
        # Check if the object has been tagged
        case ObjectRegistry.get_tag(arg)
        when EventLoop
          InternalObject.new(arg, event_loop)
        when :extern
          ExternalObject.new(arg, event_loop)
        else
          # Not tagged -> try to deep copy the object
          begin
            dumped = Marshal.dump(arg)
          rescue TypeError
            # Object not copyable -> wrap object as internal or external object
            sanity_before_queue2(mutable_object(arg))
          else
            Marshal.load(dumped)
          end
        end
      end
    end

    def sanity_before_queue(args)
      args.is_a?(Array) ? args.map(&method(:sanity_before_queue2)) : sanity_before_queue2(args)
    end

    def sanity_after_queue2(arg)
      case arg
      when InternalObject, ExternalObject
        arg.access_allowed? ? arg.object : arg
      else
        arg
      end
    end

    def sanity_after_queue(args)
      args.is_a?(Array) ? args.map(&method(:sanity_after_queue2)) : sanity_after_queue2(args)
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
end
