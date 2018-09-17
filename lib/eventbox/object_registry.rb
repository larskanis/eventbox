class Eventbox
  class ObjectRegistry
    class << self
      @@objects = {}
      @@mutex = Mutex.new

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
        @@mutex.synchronize do
          tag = @@objects[object.object_id]
          if tag && tag != owning_thread
            raise InvalidAccess, "object #{object.inspect} is already tagged to #{tag.inspect}"
          end
          @@objects[object.object_id] = owning_thread
        end
        ObjectSpace.define_finalizer(object, method(:untag))
      end

      def get_tag(object)
        @@mutex.synchronize do
          @@objects[object.object_id]
        end
      end

      def untag(object_id)
        @@mutex.synchronize do
          @@objects.delete(object_id)
        end
      end
    end
  end
end
