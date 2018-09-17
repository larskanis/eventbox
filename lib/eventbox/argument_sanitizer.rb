class Eventbox
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

  module ArgumentSanitizer
    private

    def return_args(args)
      args.length <= 1 ? args.first : args
    end

    def sanity_before_queue(args, ctrl_thread=@ctrl_thread)
      pr = proc do |arg|
        case arg
        # If object is already wrapped -> pass through
        when InternalObject, ExternalObject
          arg
        else
          # Check if the object has been tagged
          case ObjectRegistry.get_tag(arg)
          when Thread
            InternalObject.new(arg, ctrl_thread)
          when :extern
            ExternalObject.new(arg, ctrl_thread)
          else
            # Not tagged -> try to deep copy the object
            begin
              dumped = Marshal.dump(arg)
            rescue TypeError
              # Object not copyable -> wrap object as internal or external object
              pr.call(mutable_object(arg))
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

    public

    def mutable_object(object)
      if Thread.current == @ctrl_thread
        ObjectRegistry.set_tag(object, @ctrl_thread)
      else
        ObjectRegistry.set_tag(object, :extern)
      end
      object
    end
  end
end
