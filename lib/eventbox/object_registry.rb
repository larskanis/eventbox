# frozen-string-literal: true

class Eventbox
  class ObjectRegistry
    class << self
      def taggable?(object)
        case object
        # Keep the list of non taggable object types in sync with Sanitizer.sanitize_value
        when NilClass, Numeric, Symbol, TrueClass, FalseClass, WrappedObject, Action, Module, Eventbox, Proc
          false
        else
          if object.frozen?
            false
          else
            true
          end
        end
      end

      def set_tag(object, new_tag)
        raise InvalidAccess, "object is not taggable: #{object.inspect}" unless taggable?(object)

        tag = get_tag(object)
        if tag && tag != new_tag
          raise InvalidAccess, "object #{object.inspect} is already tagged to #{tag.inspect}"
        end
        object.instance_variable_set(:@__event_box_tag__, new_tag)
      end

      def get_tag(object)
        object.instance_variable_defined?(:@__event_box_tag__) && object.instance_variable_get(:@__event_box_tag__)
      end
    end
  end
end
