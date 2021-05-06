# frozen-string-literal: true

class Eventbox
  module ArgumentWrapper
    def self.build(method, name)
      parameters = method.parameters
      if parameters.find { |t, n| n.to_s.start_with?("€") }

        # Change a Proc object to a Method, so that we are able to differ between :opt and :req parameters.
        # This is because Ruby (wrongly IMHO) reports required parameters as optional.
        # The only way to get the true parameter types is through define_method.
        is_proc = Proc === method
        if is_proc
          cl = Class.new do
            define_method(:to_method, &method)
          end
          method = cl.instance_method(:to_method)
          parameters = method.parameters
        end

        decls = []
        convs = []
        rets = []
        kwrets = []
        parameters.each_with_index do |(t, n), i|
          €var = n.to_s.start_with?("€")
          case t
          when :req
            decls << n
            if €var
              convs << "#{n} = Sanitizer.wrap_object(#{n}, source_event_loop, target_event_loop, :#{n})"
            end
            rets << n
          when :opt
            decls << "#{n}=nil"
            if €var
              convs << "#{n} = #{n} ? Sanitizer.wrap_object(#{n}, source_event_loop, target_event_loop, :#{n}) : []"
            end
            rets << "*#{n}"
          when :rest
            decls << "*#{n}"
            if €var
              convs << "#{n}.map!{|v| Sanitizer.wrap_object(v, source_event_loop, target_event_loop, :#{n}) }"
            end
            rets << "*#{n}"
          when :keyreq
            decls << "#{n}:"
            if €var
              convs << "#{n} = Sanitizer.wrap_object(#{n}, source_event_loop, target_event_loop, :#{n})"
            end
            kwrets << "#{n}: #{n}"
          when :key
            decls << "#{n}:nil"
            if €var
              convs << "#{n} = #{n} ? {#{n}: Sanitizer.wrap_object(#{n}, source_event_loop, target_event_loop, :#{n})} : {}"
            else
              convs << "#{n} = #{n} ? {#{n}: #{n}} : {}"
            end
            kwrets << "**#{n}"
          when :keyrest
            decls << "**#{n}"
            if €var
              convs << "#{n}.transform_values!{|v| Sanitizer.wrap_object(v, source_event_loop, target_event_loop, :#{n}) }"
            end
            kwrets << "**#{n}"
          when :block
            if €var
              raise "block to `#{name}' can't be wrapped"
            end
          end
        end
        code = "#{is_proc ? :proc : :lambda} do |source_event_loop, target_event_loop#{decls.map{|s| ",#{s}"}.join }| # #{name}\n  #{convs.join("\n")}\n  [[#{rets.join(",")}],{#{kwrets.join(",")}}]\nend"
        instance_eval(code, "wrapper code defined in #{__FILE__}:#{__LINE__} for #{name}")
      end
    end
  end
end
