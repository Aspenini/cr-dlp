require "deque"
require "json"
require "math"

module CrDlp
  # Sentinel for missing optional values (yt-dlp NO_DEFAULT).
  module NoDefault
  end

  # JavaScript undefined value.
  struct JSUndefined
    def to_s(io : IO)
      io << "undefined"
    end
  end

  JS_UNDEFINED = JSUndefined.new

  class JSBreak < ExtractorError
    def initialize
      super("Invalid break")
    end
  end

  class JSContinue < ExtractorError
    def initialize
      super("Invalid continue")
    end
  end

  class JSThrow < ExtractorError
    getter error : JSValue

    def initialize(@error : JSValue)
      super("Uncaught exception #{@error}")
    end
  end

  alias JSValue = Int32 | Int64 | Float64 | String | Bool | Nil | Array(JSValue) | Hash(String, JSValue) | JSUndefined | FunctionWithRepr | Symbol

  alias GlobalStackEntry = LocalNameSpace | Hash(String, JSValue) | Hash(String, FunctionWithRepr)

  struct FunctionWithRepr
    @func : Proc(Array(JSValue), Hash(String, JSValue), Int32, JSValue)
    @repr : String

    def initialize(@func, @repr : String)
    end

    def with_repr(repr : String) : self
      FunctionWithRepr.new(@func, repr)
    end

    def call(args : Array(JSValue), kwargs : Hash(String, JSValue) = {} of String => JSValue, allow_recursion : Int32 = 100) : JSValue
      normalized_args = [] of JSValue
      normalized_args.concat(args)
      normalized_kwargs = {} of String => JSValue
      normalized_kwargs.merge!(kwargs)
      @func.call(normalized_args, normalized_kwargs, allow_recursion)
    end

    def to_s(io : IO)
      io << @repr
    end
  end

  class LocalNameSpace
    @maps : Array(Hash(String, JSValue))

    def initialize(*maps : Hash(String, JSValue))
      @maps = maps.to_a
    end

    def initialize(@maps : Array(Hash(String, JSValue)))
    end

    def new_child(vars : Hash(String, JSValue) = {} of String => JSValue) : LocalNameSpace
      LocalNameSpace.new([vars] + @maps)
    end

    def has_key?(key : String) : Bool
      @maps.any? { |scope| scope.has_key?(key) }
    end

    def [](key : String) : JSValue
      @maps.each do |scope|
        return scope[key] if scope.has_key?(key)
      end
      raise ExtractorError.new("Key not found: #{key}")
    end

    def []?(key : String) : JSValue?
      @maps.each do |scope|
        return scope[key] if scope.has_key?(key)
      end
      nil
    end

    def []=(key : String, value : JSValue)
      @maps.each do |scope|
        if scope.has_key?(key)
          scope[key] = value
          return
        end
      end
      @maps[0][key] = value
    end

    def set_local(key : String, value : JSValue)
      @maps[0][key] = value
    end

    def get_local(key : String) : JSValue
      @maps[0][key]? || JS_UNDEFINED
    end
  end

  module JSInterpHelpers
    extend self

    def int_to_int32(n : Int64 | Int32 | Float64) : Int32
      n = n.to_i64 & 0xFFFFFFFF_i64
      n >= 0x80000000_i64 ? (n - 0x100000000_i64).to_i32 : n.to_i32
    end

    def js_truthy?(value : JSValue) : Bool
      return false if value == false || value.nil? || value == 0 || value == "" || value.is_a?(JSUndefined)
      if value.is_a?(Float64) && value.nan?
        return false
      end
      true
    end

    def js_ternary(cndn : JSValue, if_true : JSValue = true, if_false : JSValue = false) : JSValue
      js_truthy?(cndn) ? if_true : if_false
    end

    def js_zeroise(x : JSValue) : Int32
      return 0 if x.nil? || x.is_a?(JSUndefined)
      if x.is_a?(Float64) && x.nan?
        return 0
      end
      num = case x
            when Int32, Int64 then x.to_i64
            when Float64      then x.to_i64
            when String       then int_to_int32(js_to_f(x).to_i64)
            when Bool         then x ? 1_i64 : 0_i64
            else                   0_i64
            end
      int_to_int32(num)
    end

    def js_is_undefined?(value : JSValue) : Bool
      value.is_a?(JSUndefined)
    end

    def js_to_i(value : JSValue) : Int32
      case value
      when Int32, Int64 then value.to_i32
      when Float64      then value.to_i32
      when String       then value.to_i32? || 0
      when Bool         then value ? 1 : 0
      else                   0
      end
    end

    def js_to_f(value : JSValue) : Float64
      case value
      when Int32, Int64 then value.to_f
      when Float64      then value
      when String       then value.to_f? || 0.0
      when Bool         then value ? 1.0 : 0.0
      when Nil          then 0.0
      else                   0.0
      end
    end

    def js_or_zero(value : JSValue) : JSValue
      js_truthy_for_arith?(value) ? value : 0
    end

    private def js_truthy_for_arith?(value : JSValue) : Bool
      return false if value.nil?
      return false if value == false
      return false if value == 0
      return false if value == ""
      true
    end

    def js_number_to_string(val : Float64, radix : JSValue | Nil = nil) : String
      radix_val = 10
      unless radix.nil? || radix.is_a?(JSUndefined)
        radix_val = radix.to_i
      end
      raise ExtractorError.new("radix must be an integer at least 2 and no greater than 36") unless (2..36).includes?(radix_val)

      return "NaN" if val.nan?
      return "0" if val == 0
      return val < 0 ? "-Infinity" : "Infinity" if val.infinite?

      alphabet = "0123456789abcdefghijklmnopqrstuvwxyz.-"
      result = Deque(Int32).new
      sign = val < 0
      val = val.abs
      integer = val.floor
      fraction = val - integer
      delta = [Math.nextafter(0.0, Float64::INFINITY), Math.ulp(val) / 2.0].max

      if fraction >= delta
        result.push(-2) # `.`
      end

      while fraction >= delta
        delta *= radix_val.to_f
        digit_f = fraction * radix_val.to_f
        digit = digit_f.floor
        fraction = digit_f - digit
        result.push(digit.to_i32)
        needs_rounding = fraction > 0.5 || (fraction == 0.5 && (digit.to_i32 & 1) == 1)
        if needs_rounding && fraction + delta > 1.0
          index = result.size - 1
          carried = false
          while index > 0
            if result[index] + 1 < radix_val
              result[index] += 1
              carried = true
              break
            else
              result.delete_at(index)
            end
            index -= 1
          end
          integer += 1 unless carried
          break
        end
      end

      int_part = integer.to_i64
      digit = (int_part % radix_val).to_i32
      int_part //= radix_val
      result.unshift(digit)
      while int_part > 0
        digit = (int_part % radix_val).to_i32
        int_part //= radix_val
        result.unshift(digit)
      end

      result.unshift(-1) if sign # `-`

      String.build do |io|
        result.each do |d|
          io << (d == -1 ? "-" : d == -2 ? "." : alphabet[d])
        end
      end
    end

    TIMEZONE_NAMES = {
      "UT" => 0, "UTC" => 0, "GMT" => 0, "Z" => 0,
      "AST" => -4, "ADT" => -3,
      "EST" => -5, "EDT" => -4,
      "CST" => -6, "CDT" => -5,
      "MST" => -7, "MDT" => -6,
      "PST" => -8, "PDT" => -7,
    }

    DATE_FORMATS = [
      "%d %B %Y %H:%M:%S", "%B %d %Y %H:%M:%S",
      "%d %B %Y", "%d %b %Y", "%B %d %Y", "%B %dst %Y", "%B %dnd %Y", "%B %drd %Y", "%B %dth %Y",
      "%b %d %Y", "%b %dst %Y", "%b %dnd %Y", "%b %drd %Y", "%b %dth %Y",
      "%b %dst %Y %I:%M", "%b %dnd %Y %I:%M", "%b %drd %Y %I:%M", "%b %dth %Y %I:%M",
      "%Y %m %d", "%Y-%m-%d", "%Y.%m.%d.", "%Y/%m/%d", "%Y/%m/%d %H:%M", "%Y/%m/%d %H:%M:%S",
      "%Y%m%d%H%M", "%Y%m%d%H%M%S", "%Y%m%d", "%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S",
      "%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S:%f", "%d.%m.%Y %H:%M", "%d.%m.%Y %H.%M",
      "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%S.%f0Z",
      "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M",
      "%b %d %Y at %H:%M", "%b %d %Y at %H:%M:%S", "%B %d %Y at %H:%M", "%B %d %Y at %H:%M:%S",
      "%H:%M %d-%b-%Y",
      "%d-%m-%Y", "%d.%m.%Y", "%d.%m.%y", "%d/%m/%Y", "%d/%m/%y", "%d/%m/%Y %H:%M:%S",
      "%d-%m-%Y %H:%M", "%H:%M %d/%m/%Y",
      "%m-%d-%Y", "%m.%d.%Y", "%m/%d/%Y", "%m/%d/%y", "%m/%d/%Y %H:%M:%S",
    ]

    def unified_timestamp(date_str : JSValue, day_first : Bool = true, tz_offset : Int32 = 0) : Int64?
      return nil unless date_str.is_a?(String)
      s = date_str.gsub(/\s+/, " ")
      s = s.gsub(/(?i)[,|]|(mon|tues?|wed(nes)?|thu(rs)?|fri|sat(ur)?|sun)(day)?/, "")
      pm_delta = s.match(/(?i)PM/) ? 12 : 0
      timezone, s = extract_timezone(s, tz_offset)
      s = s.gsub(/(?i)\s*(?:AM|PM)(?:\s+[A-Z]+)?/, "")
      if m = s.match(/\d{1,2}:\d{1,2}(?:\.\d+)?(?P<tz>\s*[A-Z]+)$/)
        s = s[0...-((m["tz"]? || "").size)]
      end
      if m = s.match(/^([0-9]{4,}-[0-9]{1,2}-[0-9]{1,2}T[0-9]{1,2}:[0-9]{1,2}:[0-9]{1,2}\.[0-9]{6})[0-9]+$/)
        s = m[1]
      end

      DATE_FORMATS.each do |fmt|
        begin
          time = parse_time_format(s.strip, fmt)
          normalized = normalize_time_format(fmt)
          next unless flexible_date_equal?(time.to_s(normalized), s.strip)
          adjusted = time - timezone + pm_delta.hours
          return adjusted.to_unix
        rescue Time::Format::Error | ArgumentError
        end
      end
      nil
    end

    private def extract_timezone(date_str : String, tz_offset : Int32) : Tuple(Time::Span, String)
      timezone = Time::Span.zero
      s = date_str
      if m = s.match(/(\d{1,2}:\d{1,2}(?:\.\d+)?)(?P<tz>\s*[A-Z]+)$/)
        tz_name = (m["tz"]? || "").strip
        if hours = TIMEZONE_NAMES[tz_name]?
          s = s[0...-((m["tz"]? || "").size)]
          timezone = hours.hours
        end
      elsif m = s.match(/(?P<sign>[+-])(?P<hours>[0-9]{2}):?(?P<minutes>[0-9]{2})$/)
        sign = m["sign"] == "+" ? 1 : -1
        timezone = (sign * m["hours"].to_i).hours + (sign * m["minutes"].to_i).minutes
        s = s[0...-(m[0].size)]
      elsif tz_offset != 0
        timezone = tz_offset.hours
      end
      {timezone, s}
    end

    private def normalize_time_format(fmt : String) : String
      fmt
        .gsub("%dst", "%d").gsub("%dnd", "%d").gsub("%drd", "%d").gsub("%dth", "%d")
        .gsub("%I", "%l")
    end

    private def flexible_date_equal?(formatted : String, input : String) : Bool
      return true if formatted == input
      fmt_parts = formatted.split(/(\D+)/)
      in_parts = input.split(/(\D+)/)
      return false unless fmt_parts.size == in_parts.size
      fmt_parts.zip(in_parts).all? do |a, b|
        if a.match(/^\d+$/) && b.match(/^\d+$/)
          a.to_i64 == b.to_i64
        else
          a == b
        end
      end
    end

    private def parse_time_format(s : String, fmt : String) : Time
      Time.parse(s, normalize_time_format(fmt), Time::Location::UTC)
    end

    def remove_quotes(s : String) : String
      return s if s.size < 2
      {'"', "'"}.each do |quote|
        return s[1...-1] if s.starts_with?(quote) && s.ends_with?(quote)
      end
      s
    end

    def js_to_json(code : String, vars : Hash(String, String) = {} of String => String, strict : Bool = false) : String
      string_quotes = "'\"`"
      string_re = string_quotes.chars.map { |q| "#{Regex.escape(q.to_s)}(?:\\\\.|[^\\\\#{q}])*#{Regex.escape(q.to_s)}" }.join("|")
      comment_re = %r{/\*(?:(?!\*/).)*?\*/|//[^\n]*\n}
      skip_re = "\\s*(?:#{comment_re.source})?\\s*"

      process_escape = ->(match : Regex::MatchData) do
        escape = match[1]? || match[2]
        json_passthrough = "\"\\bfnrtu"
        if json_passthrough.includes?(escape.to_s)
          "\\#{escape}"
        elsif escape == "x"
          "\\u00"
        elsif escape == "\n"
          ""
        else
          escape.to_s
        end
      end

      fix_kv = ->(v : String) do
        return v if {"true", "false", "null"}.includes?(v)
        return "null" if {"undefined", "void 0"}.includes?(v)
        return "" if v.starts_with?("/*") || v.starts_with?("//") || v.starts_with?("!") || v == ","

        if string_quotes.includes?(v[0])
          inner = v[1...-1]
          escaped = inner.gsub(/(")|\\(.)/m, process_escape)
          return "\"#{escaped}\""
        end

        if v.match(/^(0[xX][0-9a-fA-F]+)#{skip_re}:?$/)
          i = $1.to_i(16)
          return v.ends_with?(':') ? "\"#{i}\":" : i.to_s
        end
        if v.match(/^(0+[0-7]+)#{skip_re}:?$/)
          i = $1.to_i(8)
          return v.ends_with?(':') ? "\"#{i}\":" : i.to_s
        end

        if val = vars[v]?
          unless strict
            begin
              JSON.parse(val)
              return val
            rescue JSON::ParseException
              return val.to_json
            end
          else
            return val
          end
        end

        return "\"#{v}\"" unless strict
        raise ExtractorError.new("Unknown value: #{v}")
      end

      code = code.gsub(/(?:new\s+)?Array\((.*?)\)/) { "[#{$1}]" }
      unless strict
        code = code.gsub(/new Date\((#{string_re})\)/) { $1 }
        code = code.gsub(/new \w+\((.*?)\)/) { |m| m.to_json }
        code = code.gsub(/parseInt\([^\d]+(\d+)[^\d]+\)/) { $1 }
        code = code.gsub(/\(function\([^)]*\)\s*\{[^}]*\}\s*\)\s*\(\s*(["'][^)]*["\'])\s*\)/) { $1 }
      end

      pattern = /(?:(?<s>#{string_re})|#{comment_re}|,(?=#{skip_re}[\]}])|void\s0|(?:(?<![0-9])[eE]|[a-df-zA-DF-Z_$])[.a-zA-Z_$0-9]*|\b(?:0[xX][0-9a-fA-F]+|(?<![.])0+[0-7]+)(?:#{skip_re}:)?|[0-9]+(?=#{skip_re}:)|!+)/m
      code.gsub(pattern) { |m| fix_kv.call(m) }
    end

    def truncate_string(s : String, left : Int32, right : Int32) : String
      return s if s.size <= left + right
      "#{s[0, left]}...#{s[-right, right]}"
    end

    def json_any_to_js_value(value : JSON::Any) : JSValue
      case raw = value.raw
      when Nil     then nil
      when Bool    then raw
      when Int64   then raw.to_i32
      when Float64 then raw
      when String  then raw
      when Hash(String, JSON::Any)
        h = {} of String => JSValue
        raw.each { |k, v| h[k] = json_any_to_js_value(v) }
        h
      when Array(JSON::Any)
        raw.map { |v| json_any_to_js_value(v) }
      else
        value.to_s
      end
    end

    def parse_js_json(code : String) : JSValue
      json_any_to_js_value(JSON.parse(code))
    rescue ex : JSON::ParseException
      raise ExtractorError.new("Invalid JSON: #{ex.message}", cause: ex)
    end

    def js_value_to_json(value : JSValue) : JSON::Any
      case value
      when Nil
        JSON::Any.new(nil)
      when JSUndefined
        JSON::Any.new({"__js_undefined" => JSON::Any.new(true)})
      when Bool
        JSON::Any.new(value)
      when Int32, Int64
        JSON::Any.new(value.to_i64)
      when Float64
        if value.nan?
          JSON::Any.new({"__js_nan" => JSON::Any.new(true)})
        elsif value.infinite?
          JSON::Any.new(value < 0 ? "-Infinity" : "Infinity")
        else
          JSON::Any.new(value)
        end
      when String
        JSON::Any.new(value)
      when Array
        JSON::Any.new(value.map { |v| js_value_to_json(v) })
      when Hash
        h = Hash(String, JSON::Any).new
        value.each { |k, v| h[k] = js_value_to_json(v) }
        JSON::Any.new(h)
      when FunctionWithRepr
        JSON::Any.new({"__js_function" => JSON::Any.new(value.to_s)})
      else
        JSON::Any.new(value.to_s)
      end
    end
  end

  class JSInterpreter
    include JSInterpHelpers

    class Exception < ExtractorError
      def initialize(message : String, expr : String? = nil, cause : ::Exception? = nil)
        msg = message.rstrip
        if expr
          msg = "#{msg} in: #{JSInterpHelpers.truncate_string(expr, 50, 50)}"
        end
        super(msg, cause: cause)
      end
    end

    NAME_RE         = "[a-zA-Z_$][\\w$]*"
    NAME_REGEX      = Regex.new("^#{NAME_RE}$")
    MATCHING_PARENS = {'(' => ')', '{' => '}', '[' => ']'}
    QUOTES          = "'\"/"
    NESTED_BRACKETS = %r{[^[\]]+(?:\[[^[\]]+(?:\[[^\]]+\])?\])?}
    OPERATOR_ORDER  = [
      "??", "?", "||", "&&",
      "|", "^", "&",
      "===", "!==", "==", "!=", "<=", ">=", ">>", "<<", "<", ">",
      "+", "-",
      "**", "*", "%", "/",
    ]
    COMP_OPERATORS = {"===", "!==", "==", "!=", "<=", ">=", "<", ">"}
    @@named_object_counter = 0

    RE_FLAGS = {
      'd' => 1024,
      'g' => 2048,
      'i' => 1,
      'm' => 8,
      's' => 16,
      'u' => 256,
      'y' => 4096,
    }

    @code : String
    @functions : Hash(String, FunctionWithRepr)
    @objects : Hash(String, Hash(String, JSValue))
    @undefined_varnames : Set(String)
    getter undefined_varnames : Set(String)

    def initialize(@code : String, objects : Hash(String, Hash(String, JSValue))? = nil)
      @functions = {} of String => FunctionWithRepr
      @objects = objects || {} of String => Hash(String, JSValue)
      @undefined_varnames = Set(String).new
    end

    def js_bit_op(op : Proc(Int32, Int32, Int32)) : Proc(JSValue, JSValue, JSValue)
      ->(a : JSValue, b : JSValue) : JSValue do
        int_to_int32(op.call(js_zeroise(a), js_zeroise(b)))
      end
    end

    def js_arith_op(op : Proc(Float64, Float64, Float64)) : Proc(JSValue, JSValue, JSValue)
      ->(a : JSValue, b : JSValue) : JSValue do
        return Float64::NAN if js_is_undefined?(a) || js_is_undefined?(b)
        a_val = js_or_zero(a)
        b_val = js_or_zero(b)
        op.call(js_to_f(a_val), js_to_f(b_val))
      end
    end

    def js_div(a : JSValue, b : JSValue) : Float64
      return Float64::NAN if js_is_undefined?(a) || js_is_undefined?(b)
      a_val = js_or_zero(a)
      b_val = js_or_zero(b)
      return Float64::NAN unless js_truthy_for_arith?(a_val) || js_truthy_for_arith?(b_val)
      return Float64::INFINITY if b_val == 0
      js_to_f(a_val) / js_to_f(b_val)
    end

    def js_mod(a : JSValue, b : JSValue) : Float64
      return Float64::NAN if js_is_undefined?(a) || js_is_undefined?(b)
      return Float64::NAN if b.nil? || b == false || b == 0 || b == 0.0 || b == "" || b.is_a?(JSUndefined)
      js_to_f(js_or_zero(a)) % js_to_f(b)
    end

    def js_exp(a : JSValue, b : JSValue) : JSValue
      unless b.is_a?(JSUndefined)
        return 1 if b.nil? || b == false || b == 0 || b == 0.0 || b == ""
      end
      return Float64::NAN if js_is_undefined?(a) || js_is_undefined?(b)
      js_to_f(js_or_zero(a)) ** js_to_f(js_or_zero(b))
    end

    def js_eq_op(cmp : Proc(JSValue, JSValue, Bool)) : Proc(JSValue, JSValue, JSValue)
      ->(a : JSValue, b : JSValue) : JSValue do
        if (a.nil? || js_is_undefined?(a)) && (b.nil? || js_is_undefined?(b))
          cmp.call(a, a)
        else
          cmp.call(a, b)
        end
      end
    end

    def js_compare(a : JSValue, b : JSValue, op : String) : Bool
      return false if js_is_undefined?(a) || js_is_undefined?(b)
      if a.is_a?(String) || b.is_a?(String)
        astr = (a.nil? ? "0" : a).to_s
        bstr = (b.nil? ? "0" : b).to_s
        case op
        when "<=" then astr <= bstr
        when ">=" then astr >= bstr
        when "<"  then astr < bstr
        when ">"  then astr > bstr
        else           false
        end
      else
        af = js_to_f(js_or_zero(a))
        bf = js_to_f(js_or_zero(b))
        case op
        when "<=" then af <= bf
        when ">=" then af >= bf
        when "<"  then af < bf
        when ">"  then af > bf
        else           false
        end
      end
    end

    OPERATORS = {} of String => (Proc(JSValue, JSValue, JSValue) | Nil)

    def self.build_operators
      ops = {} of String => (Proc(JSValue, JSValue, JSValue) | Nil)
      ops["?"] = nil
      ops["??"] = nil
      ops["||"] = nil
      ops["&&"] = nil
      helper = JSInterpreter.new("")
      ops["|"] = helper.js_bit_op(->(a : Int32, b : Int32) { a | b })
      ops["^"] = helper.js_bit_op(->(a : Int32, b : Int32) { a ^ b })
      ops["&"] = helper.js_bit_op(->(a : Int32, b : Int32) { a & b })
      ops["==="] = ->(a : JSValue, b : JSValue) : JSValue { js_identical(a, b) }
      ops["!=="] = ->(a : JSValue, b : JSValue) : JSValue { !js_identical(a, b) }
      ops["=="] = helper.js_eq_op(->(a : JSValue, b : JSValue) { js_loose_equal(a, b) })
      ops["!="] = helper.js_eq_op(->(a : JSValue, b : JSValue) { !js_loose_equal(a, b) })
      ops["<="] = ->(a : JSValue, b : JSValue) : JSValue { helper.js_compare(a, b, "<=") }
      ops[">="] = ->(a : JSValue, b : JSValue) : JSValue { helper.js_compare(a, b, ">=") }
      ops["<"] = ->(a : JSValue, b : JSValue) : JSValue { helper.js_compare(a, b, "<") }
      ops[">"] = ->(a : JSValue, b : JSValue) : JSValue { helper.js_compare(a, b, ">") }
      ops[">>"] = helper.js_bit_op(->(a : Int32, b : Int32) { a >> b })
      ops["<<"] = helper.js_bit_op(->(a : Int32, b : Int32) { a << b })
      ops["+"] = helper.js_arith_op(->(a : Float64, b : Float64) { a + b })
      ops["-"] = helper.js_arith_op(->(a : Float64, b : Float64) { a - b })
      ops["*"] = helper.js_arith_op(->(a : Float64, b : Float64) { a * b })
      ops["%"] = ->(a : JSValue, b : JSValue) : JSValue { helper.js_mod(a, b) }
      ops["/"] = ->(a : JSValue, b : JSValue) : JSValue { helper.js_div(a, b) }
      ops["**"] = ->(a : JSValue, b : JSValue) : JSValue { helper.js_exp(a, b) }
      ops
    end

    @@operators : Hash(String, Proc(JSValue, JSValue, JSValue) | Nil) = build_operators

    private def self.js_identical(a : JSValue, b : JSValue) : Bool
      if a.is_a?(JSUndefined) && b.is_a?(JSUndefined)
        true
      elsif a.nil? && b.nil?
        true
      elsif a.is_a?(Float64) && b.is_a?(Float64) && a.nan? && b.nan?
        true
      else
        a == b
      end
    end

    private def self.js_loose_equal(a : JSValue, b : JSValue) : Bool
      if (a.nil? || a.is_a?(JSUndefined)) && (b.nil? || b.is_a?(JSUndefined))
        true
      else
        a == b
      end
    end

    private def self.js_compare_numeric(a : JSValue, b : JSValue, op : String) : Bool
      return false if js_is_undefined?(a) || js_is_undefined?(b)
      a_val = a.is_a?(String) || b.is_a?(String) ? (a || 0).to_s : (a.nil? ? 0.0 : a.to_f)
      b_val = a.is_a?(String) || b.is_a?(String) ? (b || 0).to_s : (b.nil? ? 0.0 : b.to_f)
      if a.is_a?(String) || b.is_a?(String)
        case op
        when "<=" then a_val.to_s <= b_val.to_s
        when ">=" then a_val.to_s >= b_val.to_s
        when "<"  then a_val.to_s < b_val.to_s
        when ">"  then a_val.to_s > b_val.to_s
        else           false
        end
      else
        af = a_val.is_a?(String) ? 0.0 : a_val.to_f
        bf = b_val.is_a?(String) ? 0.0 : b_val.to_f
        case op
        when "<=" then af <= bf
        when ">=" then af >= bf
        when "<"  then af < bf
        when ">"  then af > bf
        else           false
        end
      end
    end

    private def named_object(namespace : Hash(String, JSValue), obj : JSValue) : String
      @@named_object_counter += 1
      name = "__yt_dlp_jsinterp_obj#{@@named_object_counter}"
      wrapped = obj
      if obj.is_a?(FunctionWithRepr)
        wrapped = obj
      elsif obj.responds_to?(:call)
        wrapped = obj
      end
      namespace[name] = wrapped
      name
    end

    private def regex_flags(expr : String) : Tuple(Int32, String)
      flags = 0
      return {flags, expr} if expr.empty?
      idx = 0
      expr.each_char do |ch|
        if f = RE_FLAGS[ch]?
          flags |= f
          idx += 1
        else
          break
        end
      end
      {flags, expr[idx..]? || ""}
    end

    def self.separate(expr : String, delim : String = ",", max_split : Int32? = nil) : Array(String)
      return [] of String if expr.empty?

      op_chars = "+-*/%&|^=<>!,;{}:["
      counters = MATCHING_PARENS.values.to_h { |v| {v, 0} }
      start = 0
      splits = 0
      pos = 0
      delim_len = delim.size - 1
      in_quote = nil.as(Char?)
      escaping = false
      after_op = true.as(Bool | Char)
      in_regex_char_group = false
      results = [] of String

      expr.each_char.with_index do |char, idx|
        if !in_quote && MATCHING_PARENS.has_key?(char)
          counters[MATCHING_PARENS[char]] += 1
        elsif !in_quote && counters.has_key?(char) && counters[char] > 0
          counters[char] -= 1
        elsif !escaping
          if QUOTES.includes?(char) && (in_quote == char || in_quote.nil?)
            if in_quote || after_op == true || char != '/'
              in_quote = in_quote && !in_regex_char_group ? nil : char
            end
          elsif in_quote == '/' && char.in?({'[', ']'})
            in_regex_char_group = char == '['
          end
        end
        escaping = !escaping && !!in_quote && char == '\\'
        in_unary_op = !in_quote && !in_regex_char_group &&
                      !(after_op == true || after_op == false) && char.in?({'-', '+'})
        after_op = if !in_quote && op_chars.includes?(char)
                     char
                   elsif char.whitespace?
                     after_op
                   else
                     false
                   end

        unless char != delim[pos]? || counters.values.any?(&.> 0) || in_quote || in_unary_op
          if pos != delim_len
            pos += 1
          else
            results << expr[start...idx - delim_len]
            start = idx + 1
            pos = 0
            splits += 1
            break if max_split && splits >= max_split
          end
        else
          pos = 0
        end
      end

      results << expr[start..]
      results
    end

    def self.separate_at_paren(expr : String, delim : Char? = nil) : Tuple(String, String)
      delim_char = delim || (expr.empty? ? nil : JSInterpreter::MATCHING_PARENS[expr[0]]?)
      raise Exception.new("No terminating paren #{delim_char}", expr) unless delim_char
      separated = self.separate(expr, delim_char.to_s, 1)
      raise Exception.new("No terminating paren #{delim_char}", expr) if separated.size < 2
      {separated[0][1..]? || "", separated[1].strip}
    end

    private def operator(
      op : String?,
      left_val : JSValue,
      right_expr : String,
      expr : String,
      local_vars : LocalNameSpace,
      allow_recursion : Int32,
    ) : JSValue
      case op
      when "||", "&&"
        short = (op == "&&") ^ js_truthy?(left_val)
        return left_val if short
      when "??"
        return left_val unless left_val.nil? || left_val.is_a?(JSUndefined)
      when "?"
        parts = [] of String
        self.class.separate(right_expr, ":", 1).each { |p| parts << p }
        right_expr = js_ternary(left_val, parts[0]? || "", parts[1]? || "")
      end

      right_val = interpret_expression(right_expr, local_vars, allow_recursion)
      op_proc = @@operators[op]? if op
      return right_val unless op_proc

      if op == "+" && (left_val.is_a?(String) || right_val.is_a?(String))
        return "#{left_val}#{right_val}"
      end

      begin
        op_proc.not_nil!.call(left_val, right_val)
      rescue ex : ExtractorError
        raise ex
      end
    end

    private def js_char_code_at(text : String, idx : Int32) : JSValue
      return nil if idx >= text.size
      text[idx].ord
    end

    private def index(obj : JSValue, idx : JSValue, allow_undefined : Bool = false) : JSValue
      if idx == "length"
        return obj.as(Array).size if obj.is_a?(Array)
        return obj.as(String).size if obj.is_a?(String)
      end
      begin
        if obj.is_a?(Array)
          obj[js_to_i(idx)]
        elsif obj.is_a?(Hash(String, JSValue))
          key = idx.is_a?(String) ? idx.as(String) : js_to_i(idx).to_s
          return JS_UNDEFINED if allow_undefined && !obj.has_key?(key)
          obj[key]
        else
          raise Exception.new("Cannot get index #{idx}", obj.to_s)
        end
      rescue ex : ExtractorError
        raise ex
      end
    end

    private def dump(obj : JSValue, namespace : Hash(String, JSValue)) : String
      js_value_to_json(obj).to_json
    end

    def interpret_statement(
      stmt : String,
      local_vars : LocalNameSpace,
      allow_recursion : Int32 = 100,
      is_var_declaration : Bool = false,
    ) : Tuple(JSValue, Bool)
      raise Exception.new("Recursion limit reached") if allow_recursion < 0
      allow_recursion -= 1

      should_return = false
      sub_statements = [] of String
      self.class.separate(stmt, ";").each { |s| sub_statements << s }
      sub_statements = [""] if sub_statements.empty?
      expr = stmt = sub_statements.pop.strip

      sub_statements.each do |sub_stmt|
        ret, should_return = interpret_statement(sub_stmt, local_vars, allow_recursion)
        return {ret, should_return} if should_return
      end

      prefix_m = stmt.match(%r{(?P<var>(?:var|const|let)\s)|return(?:\s+|(?=["\x27])|$)|(?P<throw>throw\s+)})
      if prefix_m && prefix_m.begin(0) == 0
        m = prefix_m
        prefix = m[0]
        expr = (stmt[prefix.size..] || "").strip
        if m["throw"]?
          raise JSThrow.new(interpret_expression(expr, local_vars, allow_recursion))
        end
        should_return = !m["var"]?
        is_var_declaration = is_var_declaration || !!m["var"]?
      end
      return {nil, should_return} if expr.empty?

      if QUOTES.includes?(expr[0])
        inner_parts = [] of String
        self.class.separate(expr, expr[0].to_s, 1).each { |p| inner_parts << p }
        inner = inner_parts[0]? || ""
        outer = inner_parts[1]? || ""
        if expr[0] == '/'
          _flags, outer = regex_flags(outer)
          inner = "#{inner}/#{_flags}"
        else
          inner = parse_js_json(js_to_json("#{inner}#{expr[0]}", strict: true))
        end
        unless outer.empty?
          expr = named_object(local_vars.as_hash, inner) + outer
        else
          return {inner, should_return}
        end
      end

      if expr.starts_with?("new ")
        new_obj = expr[4..]
        if new_obj.starts_with?("Date(")
          left, right = self.class.separate_at_paren(new_obj[4..]? || "")
          date = unified_timestamp(interpret_expression(left, local_vars, allow_recursion), false)
          raise Exception.new("Failed to parse date #{left.inspect}", expr) unless date
          expr = dump((date * 1000).to_i, local_vars.as_hash) + right
        else
          raise Exception.new("Unsupported object #{new_obj}", expr)
        end
      end

      if expr.starts_with?("void ")
        interpret_expression(expr[5..]? || "", local_vars, allow_recursion)
        return {nil, should_return}
      end

      if expr.starts_with?("{")
        inner, outer = self.class.separate_at_paren(expr)
        sub_exprs = [] of Array(String)
        self.class.separate(inner).each do |sub|
          parts = [] of String
          self.class.separate(sub.strip, ":", 1).each { |p| parts << p }
          sub_exprs << parts
        end
        if sub_exprs.all? { |se| se.size == 2 }
          result = {} of String => JSValue
          sub_exprs.each do |pair|
            k, v = pair[0], pair[1]
            val = interpret_expression(v, local_vars, allow_recursion)
            key = if k.match(NAME_REGEX)
                    k
                  else
                    interpret_expression(k, local_vars, allow_recursion).to_s
                  end
            result[key] = val
          end
          return {result, should_return}
        end
        inner_val, should_abort = interpret_statement(inner, local_vars, allow_recursion)
        if outer.empty? || should_abort
          return {inner_val, should_abort || should_return}
        else
          expr = dump(inner_val, local_vars.as_hash) + outer
        end
      end

      if expr.starts_with?("(")
        inner, outer = self.class.separate_at_paren(expr)
        inner_val, should_abort = interpret_statement(inner, local_vars, allow_recursion)
        if outer.empty? || should_abort
          return {inner_val, should_abort || should_return}
        else
          expr = dump(inner_val, local_vars.as_hash) + outer
        end
      end

      if expr.starts_with?("[")
        inner, outer = self.class.separate_at_paren(expr)
        items = [] of JSValue
        self.class.separate(inner).each do |item|
          items << interpret_expression(item, local_vars, allow_recursion)
        end
        expr = named_object(local_vars.as_hash, items) + outer
      end

      ctrl_m = expr.match(/(?P<try>try)\s*\{|(?P<if>if)\s*\(|(?P<switch>switch)\s*\(|(?P<for>for)\s*\(/)
      if ctrl_m && ctrl_m.begin(0) == 0
        m = ctrl_m
        md = {
          "try"    => !!m["try"]?,
          "if"     => !!m["if"]?,
          "switch" => !!m["switch"]?,
          "for"    => !!m["for"]?,
        }

        remainder = expr

        if md["if"]
          cndn, remainder = self.class.separate_at_paren(expr[m.end(0) - 1..]? || "")
          if_expr, remainder = self.class.separate_at_paren(remainder.lstrip)
          else_expr = nil.as(String?)
          if em = remainder.match(/else\s*\{/)
            else_expr, remainder = self.class.separate_at_paren(remainder[em.end(0) - 1..]? || "")
          end
          cndn_val = js_truthy?(interpret_expression(cndn, local_vars, allow_recursion))
          branch = cndn_val ? if_expr : else_expr
          if branch
            ret, should_abort = interpret_statement(branch, local_vars, allow_recursion)
            return {ret, true} if should_abort
          end
        end

        if md["try"]
          try_expr, remainder = self.class.separate_at_paren(expr[m.end(0) - 1..]? || "")
          err : ExtractorError? = nil
          begin
            ret, should_abort = interpret_statement(try_expr, local_vars, allow_recursion)
            return {ret, true} if should_abort
          rescue ex : ExtractorError
            err = ex
          end

          pending = {nil, false}
          if cm = remainder.match(/catch\s*(?P<err>\(\s*#{NAME_RE}\s*\))?\{/)
            catch_body, remainder = self.class.separate_at_paren(remainder[cm.end(0) - 1..]? || "")
            if err
              catch_vars = {} of String => JSValue
              if cm["err"]?
                caught = err.is_a?(JSThrow) ? err.error : err.message.as(JSValue)
                catch_vars[cm["err"]? || ""] = caught
              end
              catch_scope = local_vars.new_child(catch_vars)
              pending = interpret_statement(catch_body, catch_scope, allow_recursion)
            end
          end

          if fm = remainder.match(/finally\s*\{/)
            finally_body, remainder = self.class.separate_at_paren(remainder[fm.end(0) - 1..]? || "")
            ret, should_abort = interpret_statement(finally_body, local_vars, allow_recursion)
            return {ret, true} if should_abort
          end

          ret, should_abort = pending
          return {ret, true} if should_abort
          raise err if err
        elsif md["for"]
          constructor, remaining = self.class.separate_at_paren(expr[m.end(0) - 1..]? || "")
          if remaining.starts_with?("{")
            body, remainder = self.class.separate_at_paren(remaining)
          elsif sm = remaining.match(/switch\s*\(/)
            switch_val, rem2 = self.class.separate_at_paren(remaining[sm.end(0) - 1..]? || "")
            body, remainder = self.class.separate_at_paren(rem2, '}')
            body = "switch(#{switch_val}){#{body}}"
          else
            body = remaining
            remainder = ""
          end
          parts = [] of String
          self.class.separate(constructor, ";").each { |p| parts << p }
          start_expr = parts[0]? || ""
          cndn_expr = parts[1]? || ""
          increment_expr = parts[2]? || ""
          interpret_expression(start_expr, local_vars, allow_recursion)
          loop do
            break unless js_truthy?(interpret_expression(cndn_expr, local_vars, allow_recursion))
            begin
              ret, should_abort = interpret_statement(body, local_vars, allow_recursion)
              return {ret, true} if should_abort
            rescue ex : ExtractorError
              case ex
              when JSBreak
                break
              when JSContinue
                # continue for-loop
              else
                raise ex
              end
            end
            interpret_expression(increment_expr, local_vars, allow_recursion)
          end
        elsif md["switch"]
          switch_val, remaining = self.class.separate_at_paren(expr[m.end(0) - 1..]? || "")
          switch_val = interpret_expression(switch_val, local_vars, allow_recursion)
          body, remainder = self.class.separate_at_paren(remaining, '}')
          items = body.gsub("default:", "case default:").split("case ")[1..]? || [] of String
          {false, true}.each do |default_pass|
            matched = false
            items.each do |item|
              case_parts = [] of String
              self.class.separate(item, ":", 1).each { |p| case_parts << p.strip }
              case_expr = case_parts[0]? || ""
              stmt_body = case_parts[1]? || ""
              if default_pass
                matched = matched || case_expr == "default"
              elsif !matched
                matched = case_expr != "default" &&
                          switch_val == interpret_expression(case_expr, local_vars, allow_recursion)
              end
              next unless matched
              begin
                ret, should_abort = interpret_statement(stmt_body, local_vars, allow_recursion)
                return {ret, true} if should_abort
              rescue ex : ExtractorError
                case ex
                when JSBreak
                  break
                else
                  raise ex
                end
              end
            end
            break if matched
          end
        end

        ret, should_abort = interpret_statement(remainder, local_vars, allow_recursion)
        return {ret, should_abort || should_return}
      end

      sub_exprs = [] of String
      self.class.separate(expr).each { |s| sub_exprs << s }
      if sub_exprs.size > 1
        ret = nil
        sub_exprs.each do |sub_expr|
          ret, should_abort = interpret_statement(sub_expr, local_vars, allow_recursion, is_var_declaration: is_var_declaration)
          return {ret, true} if should_abort
        end
        return {ret, false}
      end

      assign_ops = @@operators.keys.reject { |k| COMP_OPERATORS.to_a.includes?(k) }.map { |k| Regex.escape(k) }.join("|")
      assign_re = /(?P<out>#{NAME_RE})(?:\[(?P<index>#{NESTED_BRACKETS.source})\])?\s*(?P<op>#{assign_ops})?=(?!=)(?P<expr>.*)$/x
      assign_m = expr.match(assign_re)
      if assign_m && assign_m.begin(0) == 0
        m = assign_m
        out_name = m["out"]? || ""
        left_val = local_vars.has_key?(out_name) ? local_vars[out_name] : nil
        if m["index"]?.nil?
          eval_result = operator(
            m["op"]?,
            left_val,
            m["expr"]? || "",
            expr,
            local_vars,
            allow_recursion,
          )
          if is_var_declaration
            local_vars.set_local(m["out"]? || "", eval_result)
          else
            local_vars[m["out"]? || ""] = eval_result
          end
          return {local_vars[m["out"]? || ""], should_return}
        elsif left_val.nil? || left_val.is_a?(JSUndefined)
          raise Exception.new("Cannot index undefined variable #{m["out"]}", expr)
        else
          idx = interpret_expression(m["index"]? || "", local_vars, allow_recursion)
          unless idx.is_a?(Int32) || idx.is_a?(Int64) || idx.is_a?(Float64)
            raise Exception.new("List index #{idx} must be integer", expr)
          end
          idx_i = js_to_i(idx)
          current = index(left_val, idx_i)
          new_val = operator(m["op"]?, current, m["expr"]? || "", expr, local_vars, allow_recursion)
          if left_val.is_a?(Array)
            left_val.as(Array)[idx_i] = new_val
          end
          return {new_val, should_return}
        end
      end

      unless expr.match(/(?:\A(?:try\s*\{|if\s*\(|switch\s*\(|for\s*\())/)
        expr.scan(/(?P<pre_sign>\+\+|--)(?P<var1>#{NAME_RE})|(?P<var2>#{NAME_RE})(?P<post_sign>\+\+|--)/) do |m|
          var = m["var1"]? || m["var2"]? || ""
          start = m.begin(0)
          ending = m.end(0)
          sign = m["pre_sign"]? || m["post_sign"]? || ""
          ret = local_vars[var]
          current = js_to_f(ret).to_i
          local_vars[var] = current + (sign.starts_with?("+") ? 1 : -1)
          ret = local_vars[var] if m["pre_sign"]?
          expr = expr[0...start] + dump(ret, local_vars.as_hash) + expr[ending..]
        end
      end

      return {nil, should_return} if expr.empty?

      final_re = /
        (?P<return>(?!if|return|true|false|null|undefined|NaN)(?P<name>#{NAME_RE})$)|
        (?P<attribute>(?P<var>#{NAME_RE})(?:(?P<nullish>\?)?\.(?P<member>[^(]+)|\[(?P<member2>#{NESTED_BRACKETS.source})\])\s*)|
        (?P<indexing>(?P<in>#{NAME_RE})\[(?P<idx>.+)\]$)|
        (?P<function>(?P<fname>#{NAME_RE})\((?P<args>.*)\)$)
      /x

      m = expr.match(final_re)

      if expr.match(/^-?\d+$/)
        return {expr.to_i64, should_return}
      elsif expr == "break"
        raise JSBreak.new
      elsif expr == "continue"
        raise JSContinue.new
      elsif expr == "undefined"
        return {JS_UNDEFINED, should_return}
      elsif expr == "true"
        return {true, should_return}
      elsif expr == "false"
        return {false, should_return}
      elsif expr == "null"
        return {nil, should_return}
      elsif expr == "NaN"
        return {Float64::NAN, should_return}
      elsif m && m["return"]? && m[0] == expr
        var = m["name"]? || ""
        ret = if is_var_declaration
                existing = local_vars.get_local(var)
                local_vars.set_local(var, existing)
                existing
              else
                if local_vars.has_key?(var)
                  local_vars[var]
                else
                  @undefined_varnames.add(var)
                  JS_UNDEFINED
                end
              end
        return {ret, should_return}
      end

      begin
        parsed = parse_js_json(js_to_json(expr, strict: true))
        return {parsed, should_return}
      rescue ex : ExtractorError
      end

      if m && m["indexing"]?
        val = local_vars[m["in"]? || ""]
        idx = interpret_expression(m["idx"]? || "", local_vars, allow_recursion)
        return {index(val, idx), should_return}
      end

      OPERATOR_ORDER.each do |op|
        next unless @@operators.has_key?(op)
        separated = [] of String
        self.class.separate(expr, op).each { |s| separated << s }
        right_expr = separated.pop? || ""
        while true
          if op.in?("?<>*-") && separated.size > 1 && separated[-1].strip.empty?
            separated.pop
          elsif !(separated.size > 0 && op == "?" && right_expr.starts_with?("."))
            break
          else
            right_expr = "#{op}#{right_expr}"
            if op != "-"
              right_expr = "#{separated.pop}#{op}#{right_expr}"
            end
          end
        end
        next if separated.empty?
        left_val = interpret_expression(separated.join(op), local_vars, allow_recursion)
        return {operator(op, left_val, right_expr, expr, local_vars, allow_recursion), should_return}
      end

      if m && m["attribute"]?
        variable = m["var"]? || ""
        member = m["member"]? || ""
        nullish = !!m["nullish"]?
        member = interpret_expression(m["member2"]? || "", local_vars, allow_recursion).to_s if member.empty?
        arg_str : String? = nil
        remaining = expr[m.end(0)..]? || ""
        if remaining.starts_with?("(")
          arg_str, remaining = self.class.separate_at_paren(remaining)
        end

        eval_method = -> do
          if variable == "console" && member == "debug"
            return nil
          end

          types = {"String" => :string_type, "Math" => :math_type, "Array" => :array_type}
          obj = if local_vars.has_key?(variable)
                  local_vars[variable]
                elsif t = types[variable]?
                  t
                else
                  unless @objects.has_key?(variable)
                    begin
                      @objects[variable] = extract_object(variable, local_vars)
                    rescue ex : ExtractorError
                      raise ex unless nullish
                    end
                  end
                  @objects[variable]? || JS_UNDEFINED
                end

          return JS_UNDEFINED if nullish && obj.is_a?(JSUndefined)

          if arg_str.nil?
            return index(obj, member, nullish)
          end

          argvals = [] of JSValue
          self.class.separate(arg_str).each do |v|
            argvals << interpret_expression(v, local_vars, allow_recursion)
          end

          if obj.is_a?(Symbol)
            case obj
            when :string_type
              if member.starts_with?("prototype.")
                new_member, _, func_prototype = member.partition(".").last.partition(".")
                raise Exception.new("#{member} takes one or more arguments", expr) if argvals.empty?
                if func_prototype == "call"
                  obj = argvals[0]
                  argvals = argvals[1..]? || [] of JSValue
                elsif func_prototype == "apply"
                  raise Exception.new("#{member} takes two arguments", expr) unless argvals.size == 2
                  obj = argvals[0]
                  argvals = argvals[1].as(Array)
                else
                  raise Exception.new("Unsupported Function method #{func_prototype}", expr)
                end
                member = new_member
              end
              if member == "fromCharCode"
                raise Exception.new("#{member} takes one or more arguments", expr) if argvals.empty?
                return argvals.map { |v| js_to_i(v).chr }.join
              end
            when :math_type
              if member == "pow"
                raise Exception.new("#{member} takes two arguments", expr) unless argvals.size == 2
                return js_to_f(argvals[0]) ** js_to_f(argvals[1])
              end
              raise Exception.new("Unsupported Math method #{member}", expr)
            when :array_type
              if member.starts_with?("prototype.")
                new_member, _, func_prototype = member.partition(".").last.partition(".")
                raise Exception.new("#{member} takes one or more arguments", expr) if argvals.empty?
                if func_prototype == "call"
                  obj = argvals[0]
                  argvals = argvals[1..]? || [] of JSValue
                elsif func_prototype == "apply"
                  raise Exception.new("#{member} takes two arguments", expr) unless argvals.size == 2
                  obj = argvals[0]
                  argvals = argvals[1].as(Array)
                else
                  raise Exception.new("Unsupported Function method #{func_prototype}", expr)
                end
                member = new_member
              end
            end
          end

          case member
          when "split"
            raise Exception.new("#{member} takes one or more arguments", expr) if argvals.empty?
            raise Exception.new("#{member} with limit argument is not implemented", expr) unless argvals.size == 1
            s = obj.to_s
            sep = argvals[0].to_s
            parts = sep.empty? ? s.chars.map(&.to_s) : s.split(sep)
            parts.map { |part| part.as(JSValue) }
          when "join"
            raise Exception.new("#{member} must be applied on a list", expr) unless obj.is_a?(Array)
            raise Exception.new("#{member} takes exactly one argument", expr) unless argvals.size == 1
            obj.as(Array).map(&.to_s).join(argvals[0].to_s)
          when "reverse"
            raise Exception.new("#{member} does not take any arguments", expr) unless argvals.empty?
            obj.as(Array).reverse!
            return obj
          when "slice"
            raise Exception.new("#{member} must be applied on a list or string", expr) unless obj.is_a?(Array) || obj.is_a?(String)
            raise Exception.new("#{member} takes between 0 and 2 arguments", expr) if argvals.size > 2
            start = argvals[0]?.try { |v| js_to_i(v) }
            finish = argvals[1]?.try { |v| js_to_i(v) }
            return slice_value(obj, start, finish)
          when "splice"
            raise Exception.new("#{member} must be applied on a list", expr) unless obj.is_a?(Array)
            raise Exception.new("#{member} takes one or more arguments", expr) if argvals.empty?
            arr = obj.as(Array)
            index = js_to_i(argvals[0])
            how_many = argvals[1]?.try { |v| js_to_i(v) } || arr.size
            index += arr.size if index < 0
            add_items = argvals.size > 2 ? argvals[2..]? || [] of JSValue : [] of JSValue
            res = [] of JSValue
            how_many.times do
              break if index >= arr.size
              res << arr.delete_at(index)
            end
            add_items.each_with_index do |item, i|
              arr.insert(index + i, item)
            end
            res
          when "unshift"
            raise Exception.new("#{member} must be applied on a list", expr) unless obj.is_a?(Array)
            raise Exception.new("#{member} takes one or more arguments", expr) if argvals.empty?
            argvals.reverse_each { |item| obj.as(Array).unshift(item) }
            obj
          when "pop"
            raise Exception.new("#{member} must be applied on a list", expr) unless obj.is_a?(Array)
            raise Exception.new("#{member} does not take any arguments", expr) unless argvals.empty?
            return nil if obj.as(Array).empty?
            obj.as(Array).pop
          when "push"
            raise Exception.new("#{member} takes one or more arguments", expr) if argvals.empty?
            obj.as(Array).concat(argvals)
            obj
          when "forEach"
            raise Exception.new("#{member} takes one or more arguments", expr) if argvals.empty?
            raise Exception.new("#{member} takes at-most 2 arguments", expr) if argvals.size > 2
            f = argvals[0].as(FunctionWithRepr)
            this_kwargs = {} of String => JSValue
            this_kwargs["this"] = argvals[1]? || ""
            results = [] of JSValue
            obj.as(Array).each_with_index do |item, idx|
              results << f.call([item, idx, obj], this_kwargs, allow_recursion)
            end
            results
          when "indexOf"
            raise Exception.new("#{member} takes one or more arguments", expr) if argvals.empty?
            raise Exception.new("#{member} takes at-most 2 arguments", expr) if argvals.size > 2
            needle = argvals[0]
            start = argvals[1]?.try { |v| js_to_i(v) } || 0
            begin
              obj.as(Array).index(needle, start)
            rescue IndexError
              -1
            end
          when "charCodeAt"
            raise Exception.new("#{member} takes exactly one argument", expr) unless argvals.size == 1
            raise Exception.new("#{member} must be applied on a string", expr) unless obj.is_a?(String)
            js_char_code_at(obj.as(String), js_to_i(argvals[0]))
          else
            idx = obj.is_a?(Array) ? js_to_i(member) : member
            callee = index(obj, idx)
            if callee.is_a?(FunctionWithRepr)
              callee.call(argvals, allow_recursion: allow_recursion)
            else
              raise Exception.new("Unsupported method #{member}", expr)
            end
          end
        end

        if !remaining.empty?
          result = eval_method.call
          ret, should_abort = interpret_statement(
            named_object(local_vars.as_hash, result) + remaining,
            local_vars,
            allow_recursion,
          )
          return {ret, should_return || should_abort}
        else
          return {eval_method.call, should_return}
        end
      elsif m && m["function"]?
        fname = m["fname"]? || ""
        argvals = [] of JSValue
        self.class.separate(m["args"]? || "").each do |v|
          argvals << interpret_expression(v, local_vars, allow_recursion)
        end
        if local_vars.has_key?(fname)
          fn = local_vars[fname].as(FunctionWithRepr)
          return {fn.call(argvals, allow_recursion: allow_recursion), should_return}
        else
          @functions[fname] ||= extract_function(fname)
          return {@functions[fname].call(argvals, allow_recursion: allow_recursion), should_return}
        end
      end

      raise Exception.new(
        "Unsupported JS expression #{truncate_string(expr, 20, 20)}",
        stmt == expr ? nil : stmt,
      )
    end

    private def slice_value(obj : JSValue, start : Int32?, finish : Int32?) : JSValue
      s = start || 0
      if obj.is_a?(Array)
        finish.nil? ? obj.as(Array)[s..]? || [] of JSValue : obj.as(Array)[s, finish - s]
      else
        str = obj.as(String)
        finish.nil? ? str[s..]? || "" : str[s, finish - s]
      end
    end

    def interpret_expression(expr : String, local_vars : LocalNameSpace, allow_recursion : Int32) : JSValue
      ret, should_return = interpret_statement(expr, local_vars, allow_recursion)
      raise Exception.new("Cannot return from an expression", expr) if should_return
      ret
    end

    def extract_object(objname : String, *global_stack : LocalNameSpace) : Hash(String, JSValue)
      func_name_re = %((?:[a-zA-Z$0-9]+|"[a-zA-Z$0-9]+"|'[a-zA-Z$0-9]+'))
      obj_m = @code.match(/(?<![a-zA-Z$0-9.])#{Regex.escape(objname)}\s*=\s*\{\s*(?<fields>(#{func_name_re}\s*:\s*function\s*\(.*?\)\s*\{.*?\}(?:,\s*)?)*)\s*\}\s*;/m)
      raise Exception.new("Could not find object #{objname}") unless obj_m
      fields = obj_m["fields"]? || ""
      obj = {} of String => JSValue
      fields.scan(/(?P<key>#{func_name_re})\s*:\s*function\s*\((?P<args>(?:#{NAME_RE}|,)*)\)\{(?P<code>[^}]+)\}/m) do |f|
        argnames = (f["args"]? || "").split(',').map(&.strip).reject(&.empty?)
        name = remove_quotes(f["key"]? || "")
        obj[name] = FunctionWithRepr.new(
          build_function(argnames, f["code"]? || "", global_stack.to_a),
          "F<#{name}>",
        )
      end
      obj
    end

    def extract_function_code(funcname : String) : Tuple(Array(String), String)
      func_m = @code.match(
        /(?:function\s+#{Regex.escape(funcname)}|[{;,]\s*#{Regex.escape(funcname)}\s*=\s*function|(?:var|const|let)\s+#{Regex.escape(funcname)}\s*=\s*function)\s*\((?<args>[^)]*)\)\s*(?<code>\{.+\})/m,
      )
      raise Exception.new("Could not find JS function \"#{funcname}\"") unless func_m
      code, _ = self.class.separate_at_paren(func_m["code"]? || "")
      args = (func_m["args"]? || "").split(',').map(&.strip)
      {args, code}
    end

    def extract_function(funcname : String, global_stack : Array(GlobalStackEntry) = [] of GlobalStackEntry) : FunctionWithRepr
      argnames, code = extract_function_code(funcname)
      extract_function_from_code(argnames, code, global_stack).with_repr("F<#{funcname}>")
    end

    def extract_function_from_code(
      argnames : Array(String),
      code : String,
      global_stack : Array(GlobalStackEntry) = [] of GlobalStackEntry,
    ) : FunctionWithRepr
      local_vars = {} of String => JSValue
      loop do
        mobj = code.match(/function\((?<args>[^)]*)\)\s*\{/)
        break unless mobj
        start = mobj.begin(0)
        body_start = mobj.end(0)
        body, remaining = self.class.separate_at_paren(code[body_start - 1..]? || "")
        nested_args = (mobj["args"]? || "").split(',').map(&.strip)
        nested_stack = [local_vars] + global_stack
        name = named_object(local_vars, extract_function_from_code(nested_args, body, nested_stack))
        code = (code[0...start]? || "") + name + remaining
      end
      FunctionWithRepr.new(
        build_function(argnames, code, [local_vars] + global_stack),
        "F<function>",
      )
    end

    def call_function(funcname : String, args : Array(JSValue) = [] of JSValue) : JSValue
      extract_function(funcname).call(args)
    end

    def build_function(
      argnames : Array(String),
      code : String,
      global_stack : Array(GlobalStackEntry) = [] of GlobalStackEntry,
    ) : Proc(Array(JSValue), Hash(String, JSValue), Int32, JSValue)
      stacks = [] of Hash(String, JSValue)
      if global_stack.empty?
        stacks << {} of String => JSValue
      else
        global_stack.each do |entry|
          case entry
          when LocalNameSpace
            entry.@maps.each { |scope| stacks << scope }
          when Hash(String, JSValue)
            stacks << entry
          when Hash(String, FunctionWithRepr)
            stacks << {} of String => JSValue
          else
            stacks << {} of String => JSValue
          end
        end
      end
      tuple_argnames = argnames

      ->(args : Array(JSValue), kwargs : Hash(String, JSValue), allow_recursion : Int32) : JSValue do
        tuple_argnames.each_with_index do |name, i|
          stacks[0][name] = i < args.size ? args[i] : nil
        end
        kwargs.each { |k, v| stacks[0][k] = v }
        var_stack = LocalNameSpace.new(stacks)
        ret, should_abort = interpret_statement(code.gsub("\n", " "), var_stack, allow_recursion - 1)
        should_abort ? ret : nil
      end
    end
  end
end

class CrDlp::LocalNameSpace
  def as_hash : Hash(String, CrDlp::JSValue)
    @maps[0]
  end
end
