require_relative "../test_helper"

class EventboxArgumentWrapperTest < Minitest::Test

  [[:sync_call, "check.call(eb.sc(*args))", ":sc"],
   [:sync_proc, "check.call(eb.sp.call(*args))", '"sync_proc'],
   [:async_call, "eb.ac(*args); check.call(eb.async_res)", ":ac"],
   [:async_proc, "eb.ap.call(*args); check.call(eb.async_res)", '"async_proc'],
   [:yield_call, "check.call(eb.yc(*args))", ":yc"],
   [:yield_proc, "check.call(eb.yp.call(*args))", '"yield_proc'],
  ].each do |call_type, code, name|
    ["", "_bl"].each do |bn|
      code2 = bn.empty? ? code : code.gsub(/args\)/, "args){}")
      define_method("test_#{call_type}_wrap_arguments_with_rest#{bn}"){ wrap_arguments_with_rest(call_type, code2, name, bn) }
      define_method("test_#{call_type}_wrap_arguments_without_rest#{bn}"){ wrap_arguments_without_rest(call_type, code2, name, bn) }
    end
    define_method("test_#{call_type}_wrap_with_default_arguments_set"){ wrap_default_arguments_set(call_type, code, name) }
    define_method("test_#{call_type}_wrap_with_default_arguments_unset"){ wrap_default_arguments_unset(call_type, code, name) }
    define_method("test_#{call_type}_wrap_with_keyword_arguments_set"){ wrap_keyword_arguments_set(call_type, code, name) }
    define_method("test_#{call_type}_wrap_with_keyword_arguments_unset"){ wrap_keyword_arguments_unset(call_type, code, name) }
    define_method("test_#{call_type}_wrap_position_and_keyword_arguments"){ wrap_position_and_keyword_arguments(call_type, code, name) }
  end

  # Avoid "warning: assigned but unused variable - eb", etc
  def eval_code(eb, check, args, code)
    eval(code)
  end

  def wrap_arguments_with_rest(call_type, code, name, bl)
    eb = WrapArguments.new
    args = [:o1, :o2, :rest1, :rest2, :o3, :o4]
    check = proc do |res|
      assert_equal 7, res.size
      assert_equal Symbol, res[0]
      assert_equal Eventbox::ExternalObject, res[1]
      assert_equal Eventbox::ExternalObject, res[2]
      assert_equal Eventbox::ExternalObject, res[3]
      assert_equal Symbol, res[4]
      assert_equal Eventbox::ExternalObject, res[5]
      if bl.empty?
        assert_equal NilClass, res[6]
      else
        assert_equal Eventbox::ExternalProc, res[6]
      end
    end
    eval_code(eb, check, args, code)
  end

  def wrap_arguments_without_rest(call_type, code, name, bl)
    eb = WrapArguments.new
    args = [:o1, :o2, :o3, :o4]
    check = proc do |res|
      assert_equal 5, res.size
      assert_equal Symbol, res[0]
      assert_equal Eventbox::ExternalObject, res[1]
      assert_equal Symbol, res[2]
      assert_equal Eventbox::ExternalObject, res[3]
      if bl.empty?
        assert_equal NilClass, res[4]
      else
        assert_equal Eventbox::ExternalProc, res[4]
      end
    end
    eval_code(eb, check, args, code)
  end

  class WrapArguments < Eventbox
    sync_call def sc(o1, €o2, *€rest, o3, €o4, &ext_proc)
      return o1.class, €o2.class, *€rest.map(&:class), o3.class, €o4.class, ext_proc.class
    end
    sync_call def sp
      sync_proc do |o1, €o2, *€rest, o3, €o4, &ext_proc|
        [o1.class, €o2.class, *€rest.map(&:class), o3.class, €o4.class, ext_proc.class]
      end
    end
    async_call def ac(o1, €o2, *€rest, o3, €o4, &ext_proc)
      @async_res = [o1.class, €o2.class, *€rest.map(&:class), o3.class, €o4.class, ext_proc.class]
    end
    sync_call def ap
      async_proc do |o1, €o2, *€rest, o3, €o4, &ext_proc|
        @async_res = [o1.class, €o2.class, *€rest.map(&:class), o3.class, €o4.class, ext_proc.class]
      end
    end
    attr_reader :async_res
    yield_call def yc(o1, €o2, *€rest, o3, €o4, result, &ext_proc)
      result.yield o1.class, €o2.class, *€rest.map(&:class), o3.class, €o4.class, ext_proc.class
    end
    sync_call def yp
      yield_proc do |o1, €o2, *€rest, o3, €o4, result, &ext_proc|
        result.yield o1.class, €o2.class, *€rest.map(&:class), o3.class, €o4.class, ext_proc.class
      end
    end
  end

  def wrap_default_arguments_set(call_type, code, name)
    eb = WrapDefaultArguments.new
    args = [:O1, :O2, :rest1, :rest2, :O3]
    check = proc do |res|
      assert_equal 8, res.size
      assert_equal Symbol, res[0]
      assert_equal ":O1", res[1]
      assert_equal Eventbox::ExternalObject, res[2]
      assert_match(/@object=:O2 @name=:€b/, res[3])
      assert_equal Symbol, res[4]
      assert_equal Symbol, res[5]
      assert_equal Eventbox::ExternalObject, res[6]
      assert_match(/@object=:O3 @name=:€c/, res[7])
    end
    eval_code(eb, check, args, code)
  end

  def wrap_default_arguments_unset(call_type, code, name)
    eb = WrapDefaultArguments.new
    args = [:O3]
    check = proc do |res|
      assert_equal 6, res.size
      assert_equal Symbol, res[0]
      assert_equal ":A", res[1]
      assert_equal Symbol, res[2]
      assert_equal ":B", res[3]
      assert_equal Eventbox::ExternalObject, res[4]
      assert_match(/@object=:O3 @name=:€c/, res[5])
    end
    eval_code(eb, check, args, code)
  end

  class WrapDefaultArguments < Eventbox
    sync_call def sc(a=:A, €b=:B, *rest, €c)
      return a.class, a.inspect, €b.class, €b.inspect, *rest.map(&:class), €c.class, €c.inspect
    end
    sync_call def sp
      sync_proc do |a=:A, €b=:B, *rest, €c|
        [a.class, a.inspect, €b.class, €b.inspect, *rest.map(&:class), €c.class, €c.inspect]
      end
    end
    async_call def ac(a=:A, €b=:B, *rest, €c)
      @async_res = [a.class, a.inspect, €b.class, €b.inspect, *rest.map(&:class), €c.class, €c.inspect]
    end
    sync_call def ap
      async_proc do |a=:A, €b=:B, *rest, €c|
        @async_res = [a.class, a.inspect, €b.class, €b.inspect, *rest.map(&:class), €c.class, €c.inspect]
      end
    end
    attr_reader :async_res
    yield_call def yc(a=:A, €b=:B, *rest, €c, result)
      result.yield a.class, a.inspect, €b.class, €b.inspect, *rest.map(&:class), €c.class, €c.inspect
    end
    sync_call def yp
      yield_proc do |a=:A, €b=:B, *rest, €c, result|
        result.yield a.class, a.inspect, €b.class, €b.inspect, *rest.map(&:class), €c.class, €c.inspect
      end
    end
  end

  def wrap_keyword_arguments_set(call_type, code, name)
    eb = WrapKeywordArguments.new
    args = [€a: :A, b: :B, €c: :C, d: :D, g: :G, h: :H]
    check = proc do |res|
      assert_equal 10, res.size
      assert_equal Eventbox::ExternalObject, res[0]
      assert_match(/@object=:A @name=:€a/, res[1])
      assert_equal Symbol, res[2]
      assert_equal ":B", res[3]
      assert_equal Eventbox::ExternalObject, res[4]
      assert_match(/@object=:C @name=:€c/, res[5])
      assert_equal Symbol, res[6]
      assert_equal ":D", res[7]
      assert_equal [:g, Eventbox::ExternalObject], res[8]
      assert_equal [:h, Eventbox::ExternalObject], res[9]
    end
    eval_code(eb, check, args, code)
  end

  def wrap_keyword_arguments_unset(call_type, code, name)
    eb = WrapKeywordArguments.new
    args = [€a: :A1, d: :D1]
    check = proc do |res|
      assert_equal 8, res.size
      assert_equal Eventbox::ExternalObject, res[0]
      assert_match(/@object=:A1 @name=:€a/, res[1])
      assert_equal Symbol, res[2]
      assert_equal ":b", res[3]
      assert_equal Symbol, res[4]
      assert_equal ":c", res[5]
      assert_equal Symbol, res[6]
      assert_equal ":D1", res[7]
    end
    eval_code(eb, check, args, code)
  end

  class WrapKeywordArguments < Eventbox
    sync_call def sc(€a:, b: :b, €c: :c, d:, **€krest)
      return *[€a, b, €c, d].flat_map { |v| [v.class, v.inspect] }, *€krest.map{|k,v| [k, v.class] }
    end
    sync_call def sp
      sync_proc do |€a:, b: :b, €c: :c, d:, **€krest|
        [*[€a, b, €c, d].flat_map { |v| [v.class, v.inspect] }, *€krest.map{|k,v| [k, v.class] }]
      end
    end
    async_call def ac(€a:, b: :b, €c: :c, d:, **€krest)
      @async_res = [*[€a, b, €c, d].flat_map { |v| [v.class, v.inspect] }, *€krest.map{|k,v| [k, v.class] }]
    end
    sync_call def ap
      async_proc do |€a:, b: :b, €c: :c, d:, **€krest|
        @async_res = [*[€a, b, €c, d].flat_map { |v| [v.class, v.inspect] }, *€krest.map{|k,v| [k, v.class] }]
      end
    end
    attr_reader :async_res
    yield_call def yc(result, €a:, b: :b, €c: :c, d:, **€krest)
      result.yield(*[€a, b, €c, d].flat_map { |v| [v.class, v.inspect] }, *€krest.map{|k,v| [k, v.class] })
    end
    sync_call def yp
      yield_proc do |result, €a:, b: :b, €c: :c, d:, **€krest|
        result.yield(*[€a, b, €c, d].flat_map { |v| [v.class, v.inspect] }, *€krest.map{|k,v| [k, v.class] })
      end
    end
  end

  def wrap_position_and_keyword_arguments(call_type, code, name)
    eb = WrapPositionalAndKeywordArguments.new
    args = [:A, :B, g: :G, h: :H]
    check = proc do |res|
      assert_equal 6, res.size
      assert_equal Eventbox::ExternalObject, res[0]
      assert_match(/@object=:A @name=:€a/, res[1])
      assert_equal Symbol, res[2]
      assert_equal ":B", res[3]
      assert_equal [:g, Symbol], res[4]
      assert_equal [:h, Symbol], res[5]
    end
    eval_code(eb, check, args, code)
  end

  class WrapPositionalAndKeywordArguments < Eventbox
    sync_call def sc(€a, b, **krest)
      return *[€a, b].flat_map { |v| [v.class, v.inspect] }, *krest.map{|k,v| [k, v.class] }
    end
    sync_call def sp
      sync_proc do |€a, b, **krest|
        [*[€a, b].flat_map { |v| [v.class, v.inspect] }, *krest.map{|k,v| [k, v.class] }]
      end
    end
    async_call def ac(€a, b, **krest)
      @async_res = [*[€a, b].flat_map { |v| [v.class, v.inspect] }, *krest.map{|k,v| [k, v.class] }]
    end
    sync_call def ap
      async_proc do |€a, b, **krest|
        @async_res = [*[€a, b].flat_map { |v| [v.class, v.inspect] }, *krest.map{|k,v| [k, v.class] }]
      end
    end
    attr_reader :async_res
    yield_call def yc(€a, b, result, **krest)
      result.yield(*[€a, b].flat_map { |v| [v.class, v.inspect] }, *krest.map{|k,v| [k, v.class] })
    end
    sync_call def yp
      yield_proc do |€a, b, result, **krest|
        result.yield(*[€a, b].flat_map { |v| [v.class, v.inspect] }, *krest.map{|k,v| [k, v.class] })
      end
    end
  end

  def test_with_call_context
    skip "€ wrapping is not yet implemented on results of external object calls"
    eb = Class.new(Eventbox) do
      yield_call def go(€obj, result)
        €obj.send :concat, "a", -> (€r1) do
          €r1.send :concat, "b", -> (€r2) do
            result.yield ctx.class, €r2
          end
        end
      end
    end.new

    assert_equal [Eventbox::ActionCallContext, "abc"], eb.go("".dup)
  end
end
