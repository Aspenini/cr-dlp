require "./spec_helper"
require "math"

module JSInterpSpecHelpers
  def self.nan?(value)
    value.is_a?(Float64) && value.nan?
  end

  def self.assert_result(got, expected)
    if expected.is_a?(Symbol) && expected == :nan
      nan?(got).should be_true
    elsif expected.is_a?(CrDlp::JSUndefined)
      got.should be_a(CrDlp::JSUndefined)
    else
      got.should eq(expected)
    end
  end

  def self.run(code : String, expected, func = "f", args = [] of CrDlp::JSValue)
    jsi = CrDlp::JSInterpreter.new(code)
    got = jsi.call_function(func, args)
    assert_result(got, expected)
  end

  def self.run_jsi(jsi : CrDlp::JSInterpreter, expected, func = "f", args = [] of CrDlp::JSValue)
    got = jsi.call_function(func, args)
    assert_result(got, expected)
  end
end

describe CrDlp::JSInterpreter do
  describe "basic" do
    it "handles empty functions and returns" do
      jsi = CrDlp::JSInterpreter.new("function f(){;}")
      jsi.extract_function("f").to_s.should eq("F<f>")
      JSInterpSpecHelpers.run("function f(){;}", nil)
      JSInterpSpecHelpers.run("function f(){return 42;}", 42)
      JSInterpSpecHelpers.run("function f(){42}", nil)
      JSInterpSpecHelpers.run("var f = function(){return 42;}", 42)
    end
  end

  describe "arithmetic" do
    it "adds" do
      JSInterpSpecHelpers.run("function f(){return 42 + 7;}", 49)
      JSInterpSpecHelpers.run("function f(){return 42 + undefined;}", :nan)
      JSInterpSpecHelpers.run("function f(){return 42 + null;}", 42)
    end

    it "subtracts" do
      JSInterpSpecHelpers.run("function f(){return 42 - 7;}", 35)
      JSInterpSpecHelpers.run("function f(){return 42 - undefined;}", :nan)
      JSInterpSpecHelpers.run("function f(){return 42 - null;}", 42)
    end

    it "multiplies" do
      JSInterpSpecHelpers.run("function f(){return 42 * 7;}", 294)
      JSInterpSpecHelpers.run("function f(){return 42 * undefined;}", :nan)
      JSInterpSpecHelpers.run("function f(){return 42 * null;}", 0)
    end

    it "divides" do
      jsi = CrDlp::JSInterpreter.new("function f(a, b){return a / b;}")
      JSInterpSpecHelpers.run_jsi(jsi, :nan, args: [0, 0])
      JSInterpSpecHelpers.run_jsi(jsi, :nan, args: [CrDlp::JS_UNDEFINED, 1])
      JSInterpSpecHelpers.run_jsi(jsi, Float64::INFINITY, args: [2, 0])
      JSInterpSpecHelpers.run_jsi(jsi, 0, args: [0, 3])
    end

    it "mods" do
      JSInterpSpecHelpers.run("function f(){return 42 % 7;}", 0)
      JSInterpSpecHelpers.run("function f(){return 42 % 0;}", :nan)
      JSInterpSpecHelpers.run("function f(){return 42 % undefined;}", :nan)
    end

    it "exponentiates" do
      JSInterpSpecHelpers.run("function f(){return 42 ** 2;}", 1764)
      JSInterpSpecHelpers.run("function f(){return 42 ** undefined;}", :nan)
      JSInterpSpecHelpers.run("function f(){return 42 ** null;}", 1)
      JSInterpSpecHelpers.run("function f(){return undefined ** 42;}", :nan)
    end
  end

  describe "operators" do
    it "evaluates bitwise and logical operators" do
      JSInterpSpecHelpers.run("function f(){return 1 << 5;}", 32)
      JSInterpSpecHelpers.run("function f(){return 2 ** 5}", 32)
      JSInterpSpecHelpers.run("function f(){return 19 & 21;}", 17)
      JSInterpSpecHelpers.run("function f(){return 11 >> 2;}", 2)
      JSInterpSpecHelpers.run("function f(){return []? 2+3: 4;}", 5)
      JSInterpSpecHelpers.run("function f(){return 1 == 2}", false)
      JSInterpSpecHelpers.run("function f(){return 0 && 1 || 2;}", 2)
      JSInterpSpecHelpers.run("function f(){return 0 ?? 42;}", 0)
      JSInterpSpecHelpers.run("function f(){return \"life, the universe and everything\" < 42;}", false)
      JSInterpSpecHelpers.run("function f(){return 0  - 7 * - 6;}", 42)
      JSInterpSpecHelpers.run("function f(){return true << \"5\";}", 32)
      JSInterpSpecHelpers.run("function f(){return true << true;}", 2)
      JSInterpSpecHelpers.run("function f(){return \"19\" & \"21.9\";}", 17)
      JSInterpSpecHelpers.run("function f(){return \"19\" & false;}", 0)
      JSInterpSpecHelpers.run("function f(){return \"11.0\" >> \"2.1\";}", 2)
      JSInterpSpecHelpers.run("function f(){return 5 ^ 9;}", 12)
      JSInterpSpecHelpers.run("function f(){return 0.0 << NaN}", 0)
      JSInterpSpecHelpers.run("function f(){return null << undefined}", 0)
      JSInterpSpecHelpers.run("function f(){return -12616 ^ 5041}", -8951)
      JSInterpSpecHelpers.run("function f(){return 21 << 4294967297}", 42)
    end
  end

  describe "string concat" do
    it "concatenates strings and coerces numbers" do
      JSInterpSpecHelpers.run("function f(){return \"a\" + \"b\";}", "ab")
      JSInterpSpecHelpers.run("function f(){let x = \"a\"; x += \"b\"; return x;}", "ab")
      JSInterpSpecHelpers.run("function f(){return \"a\" + 1;}", "a1")
      JSInterpSpecHelpers.run("function f(){let x = \"a\"; x += 1; return x;}", "a1")
      JSInterpSpecHelpers.run("function f(){return 2 + \"b\";}", "2b")
      JSInterpSpecHelpers.run("function f(){let x = 2; x += \"b\"; return x;}", "2b")
    end
  end

  describe "assignments" do
    it "assigns and updates variables" do
      JSInterpSpecHelpers.run("function f(){var x = 20; x = 30 + 1; return x;}", 31)
      JSInterpSpecHelpers.run("function f(){var x = 20; x += 30 + 1; return x;}", 51)
      JSInterpSpecHelpers.run("function f(){var x = 20; x -= 30 + 1; return x;}", -11)
      JSInterpSpecHelpers.run("function f(){var x = 2; var y = [\"a\", \"b\"]; y[x%y[\"length\"]]=\"z\"; return y}", ["z", "b"])
    end
  end

  describe "control flow" do
    it "handles if" do
      JSInterpSpecHelpers.run(%(
        function f() {
          let a = 9;
          if (0==0) {a++}
          return a
        }
      ), 10)
      JSInterpSpecHelpers.run(%(
        function f() {
          if (0==0) {return 10}
        }
      ), 10)
      JSInterpSpecHelpers.run(%(
        function f() {
          if (0!=0) {return 1}
          else {return 10}
        }
      ), 10)
    end

    it "handles for loops" do
      JSInterpSpecHelpers.run("function f() { a=0; for (i=0; i-10; i++) {a++} return a }", 10)
      JSInterpSpecHelpers.run("function f() { a=0; for (i=0; i-10; i++) { continue; a++ } return a }", 0)
      JSInterpSpecHelpers.run("function f() { a=0; for (i=0; i-10; i++) { break; a++ } return a }", 0)
    end

    it "handles switch" do
      jsi = CrDlp::JSInterpreter.new(%(
        function f(x) { switch(x){
          case 1:x+=1;
          case 2:x+=2;
          case 3:x+=3;break;
          case 4:x+=4;
          default:x=0;
        } return x }
      ))
      JSInterpSpecHelpers.run_jsi(jsi, 7, args: [1])
      JSInterpSpecHelpers.run_jsi(jsi, 6, args: [3])
      JSInterpSpecHelpers.run_jsi(jsi, 0, args: [5])
    end

    it "handles try/catch/finally" do
      JSInterpSpecHelpers.run("function f() { try{return 10} catch(e){return 5} }", 10)
      JSInterpSpecHelpers.run("function f() { try{throw 10} catch(e){return 5} }", 5)
      JSInterpSpecHelpers.run("function f() { try{throw 10} finally {return 42} }", 42)
      JSInterpSpecHelpers.run("function f() { try{throw 10} catch(e){return 5} finally {return 42} }", 42)
    end
  end

  describe "undefined and null" do
    it "handles undefined" do
      JSInterpSpecHelpers.run("function f() { return undefined === undefined; }", true)
      JSInterpSpecHelpers.run("function f() { return undefined; }", CrDlp::JS_UNDEFINED)
      JSInterpSpecHelpers.run("function f() {return undefined ?? 42; }", 42)
      JSInterpSpecHelpers.run("function f() { let v; return v; }", CrDlp::JS_UNDEFINED)
      JSInterpSpecHelpers.run("function f() { let v; return v**0; }", 1)
      JSInterpSpecHelpers.run("function f() { return null; }", nil)
    end
  end

  describe "objects and arrays" do
    it "creates and accesses objects" do
      JSInterpSpecHelpers.run("function f() { return {}; }", {} of String => CrDlp::JSValue)
      JSInterpSpecHelpers.run("function f() { let a = {m1: 42, m2: 0 }; return [a[\"m1\"], a.m2]; }", [42, 0])
      JSInterpSpecHelpers.run("function f() { let a; return a?.qq; }", CrDlp::JS_UNDEFINED)
      JSInterpSpecHelpers.run("function f() { let a = {m1: 42, m2: 0 }; return a?.qq; }", CrDlp::JS_UNDEFINED)
      JSInterpSpecHelpers.run("function f() { let a = {\"1\": 123}; return a[1]; }", 123)
    end

    it "handles array literals" do
      JSInterpSpecHelpers.run("function f() { return [1, 2, \"asdf\", [5, 6, 7]][3] }", [5, 6, 7])
    end
  end

  describe "string methods" do
    it "charCodeAt" do
      jsi = CrDlp::JSInterpreter.new("function f(i){return \"test\".charCodeAt(i)}")
      JSInterpSpecHelpers.run_jsi(jsi, 116, args: [0])
      JSInterpSpecHelpers.run_jsi(jsi, 101, args: [1])
      JSInterpSpecHelpers.run_jsi(jsi, 115, args: [2])
      JSInterpSpecHelpers.run_jsi(jsi, 116, args: [3])
      JSInterpSpecHelpers.run_jsi(jsi, nil, args: [4])
      JSInterpSpecHelpers.run_jsi(jsi, 116, args: ["not_a_number"])
    end

    it "join" do
      input = ["t", "e", "s", "t"] of CrDlp::JSValue
      [
        "function f(a, b){return a.join(b)}",
        "function f(a, b){return Array.prototype.join.call(a, b)}",
        "function f(a, b){return Array.prototype.join.apply(a, [b])}",
      ].each do |code|
        jsi = CrDlp::JSInterpreter.new(code)
        JSInterpSpecHelpers.run_jsi(jsi, "test", args: [input, ""])
        JSInterpSpecHelpers.run_jsi(jsi, "t-e-s-t", args: [input, "-"])
        JSInterpSpecHelpers.run_jsi(jsi, "", args: [[] of CrDlp::JSValue, "-"])
      end
    end

    it "split" do
      expected = ["t", "e", "s", "t"] of CrDlp::JSValue
      [
        "function f(a, b){return a.split(b)}",
        "function f(a, b){return String.prototype.split.call(a, b)}",
      ].each do |code|
        jsi = CrDlp::JSInterpreter.new(code)
        JSInterpSpecHelpers.run_jsi(jsi, expected, args: ["test", ""])
        JSInterpSpecHelpers.run_jsi(jsi, expected, args: ["t-e-s-t", "-"])
        JSInterpSpecHelpers.run_jsi(jsi, [""], args: ["", "-"])
        JSInterpSpecHelpers.run_jsi(jsi, [] of CrDlp::JSValue, args: ["", ""])
      end
    end

    it "slice" do
      JSInterpSpecHelpers.run("function f(){return [0, 1, 2, 3, 4, 5, 6, 7, 8].slice(3, 6)}", [3, 4, 5])
      JSInterpSpecHelpers.run("function f(){return [0, 1, 2, 3, 4, 5, 6, 7, 8].slice(-2)}", [7, 8])
      JSInterpSpecHelpers.run("function f(){return \"012345678\".slice(3, 6)}", "345")
    end
  end

  describe "increment and decrement" do
    it "updates prefix and postfix operators" do
      JSInterpSpecHelpers.run("function f() { var x = 1; return ++x; }", 2)
      JSInterpSpecHelpers.run("function f() { var x = 1; return x++; }", 1)
      JSInterpSpecHelpers.run("function f() { var x = 1; x--; return x }", 0)
    end
  end

  describe "date" do
    it "parses Date expressions" do
      JSInterpSpecHelpers.run("function f() { return new Date(\"Wednesday 31 December 1969 18:01:26 MDT\") - 0; }", 86000)
      jsi = CrDlp::JSInterpreter.new("function f(dt) { return new Date(dt) - 0; }")
      JSInterpSpecHelpers.run_jsi(jsi, 86000, args: ["Wednesday 31 December 1969 18:01:26 MDT"])
      JSInterpSpecHelpers.run_jsi(jsi, 86000, args: ["12/31/1969 18:01:26 MDT"])
      JSInterpSpecHelpers.run_jsi(jsi, 0, args: ["1 January 1970 00:00:00 UTC"])
    end
  end

  describe "call" do
    it "calls nested functions" do
      jsi = CrDlp::JSInterpreter.new(%(
        function x() { return 2; }
        function y(a) { return x() + (a?a:0); }
        function z() { return y(3); }
      ))
      JSInterpSpecHelpers.run_jsi(jsi, 5, func: "z")
      JSInterpSpecHelpers.run_jsi(jsi, 2, func: "y")
    end
  end

  describe "nested scoping" do
    it "keeps inner and outer scopes separate" do
      JSInterpSpecHelpers.run(%(
        function f() {
          var g = function() {
            var P = 2;
            return P;
          };
          var P = 1;
          g();
          return P;
        }
      ), 1)
      JSInterpSpecHelpers.run(%(
        function f() {
          var P, Q;
          var z = 100;
          var g = function() {
            var P, Q; P = 2; Q = 15;
            z = 0;
            return P+Q;
          };
          P = 1; Q = 10;
          var x = g(), y = 3;
          return P+Q+x+y+z;
        }
      ), 31)
    end
  end

  describe "helpers" do
    it "converts integers to int32" do
      CrDlp::JSInterpHelpers.int_to_int32(-16799986688).should eq(379882496)
      CrDlp::JSInterpHelpers.int_to_int32(39570129568).should eq(915423904)
    end
  end
end
