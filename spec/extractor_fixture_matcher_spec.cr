require "./spec_helper"
require "digest/md5"

private module ExtractorFixtureMatcher
  extend self

  SUPPORTED_TYPES = %w[int str list dict float bool]

  def matches?(expected : JSON::Any, actual : JSON::Any) : Bool
    if object = expected.as_h?
      if type = object["$type"]?.try(&.as_s?)
        return matches_type?(type, actual)
      end
    end

    if text = expected.as_s?
      return matches_string?(text, actual)
    end

    expected == actual
  end

  def validate!(value : JSON::Any, path = "$")
    if object = value.as_h?
      if type = object["$type"]?.try(&.as_s?)
        raise "unsupported type matcher #{type.inspect} at #{path}" unless SUPPORTED_TYPES.includes?(type)
      end
      object.each do |key, child|
        validate!(child, "#{path}.#{key}") unless key == "$type"
      end
    elsif array = value.as_a?
      array.each_with_index { |child, index| validate!(child, "#{path}[#{index}]") }
    elsif text = value.as_s?
      validate_string_matcher!(text, path)
    end
  end

  private def matches_type?(type : String, actual : JSON::Any) : Bool
    case type
    when "int"   then !actual.as_i64?.nil?
    when "str"   then !actual.as_s?.nil?
    when "list"  then !actual.as_a?.nil?
    when "dict"  then !actual.as_h?.nil?
    when "float" then !actual.as_f?.nil? || !actual.as_i64?.nil?
    when "bool"  then !actual.as_bool?.nil?
    else              false
    end
  end

  private def matches_string?(expected : String, actual : JSON::Any) : Bool
    case
    when expected.starts_with?("md5:")
      Digest::MD5.hexdigest(scalar_string(actual)) == expected[4..]
    when expected.starts_with?("re:")
      Regex.new(expected[3..]).matches?(scalar_string(actual))
    when expected.starts_with?("count:")
      collection_size(actual) == expected[6..].to_i
    when expected.starts_with?("mincount:")
      collection_size(actual) >= expected[9..].to_i
    when expected.starts_with?("maxcount:")
      collection_size(actual) <= expected[9..].to_i
    when expected.starts_with?("contains:")
      contains?(actual, expected[9..])
    when expected.starts_with?("startswith:")
      scalar_string(actual).starts_with?(expected[11..])
    else
      actual.as_s? == expected
    end
  end

  private def validate_string_matcher!(expected : String, path : String)
    if expected.starts_with?("re:")
      Regex.new(expected[3..])
    elsif expected.starts_with?("md5:")
      unless expected[4..].matches?(/\A[0-9a-f]{32}\z/)
        raise "invalid md5 matcher at #{path}"
      end
    elsif expected.starts_with?("count:")
      expected[6..].to_i
    elsif expected.starts_with?("mincount:") || expected.starts_with?("maxcount:")
      expected[9..].to_i
    end
  rescue error : ArgumentError | Regex::Error
    raise "invalid matcher #{expected.inspect} at #{path}: #{error.message}"
  end

  private def collection_size(value : JSON::Any) : Int32
    value.as_a?.try(&.size) ||
      value.as_h?.try(&.size) ||
      scalar_string(value).size
  end

  private def contains?(actual : JSON::Any, needle : String) : Bool
    if array = actual.as_a?
      array.any? { |item| scalar_string(item) == needle }
    else
      scalar_string(actual).includes?(needle)
    end
  end

  private def scalar_string(value : JSON::Any) : String
    value.as_s? ||
      value.as_i64?.try(&.to_s) ||
      value.as_f?.try(&.to_s) ||
      value.as_bool?.try(&.to_s) ||
      value.to_json
  end
end

describe "extractor fixture matchers" do
  it "matches the language-neutral fixture matcher families" do
    ExtractorFixtureMatcher.matches?(JSON::Any.new({"$type" => JSON::Any.new("int")}), JSON::Any.new(3_i64)).should be_true
    ExtractorFixtureMatcher.matches?(JSON::Any.new("re:^ab+$"), JSON::Any.new("abbb")).should be_true
    ExtractorFixtureMatcher.matches?(JSON::Any.new("md5:5d41402abc4b2a76b9719d911017c592"), JSON::Any.new("hello")).should be_true
    ExtractorFixtureMatcher.matches?(JSON::Any.new("count:2"), JSON::Any.new([JSON::Any.new("a"), JSON::Any.new("b")])).should be_true
    ExtractorFixtureMatcher.matches?(JSON::Any.new("mincount:2"), JSON::Any.new([JSON::Any.new(1_i64), JSON::Any.new(2_i64), JSON::Any.new(3_i64)])).should be_true
    ExtractorFixtureMatcher.matches?(JSON::Any.new("maxcount:3"), JSON::Any.new([JSON::Any.new(1_i64)])).should be_true
    ExtractorFixtureMatcher.matches?(JSON::Any.new("contains:needle"), JSON::Any.new("hay needle stack")).should be_true
    ExtractorFixtureMatcher.matches?(JSON::Any.new("startswith:pre"), JSON::Any.new("prefix")).should be_true
    ExtractorFixtureMatcher.matches?(JSON::Any.new("exact"), JSON::Any.new("different")).should be_false
  end

  it "validates every frozen extractor fixture expectation uses supported matcher syntax" do
    suites = JSON.parse(File.read("baseline/crystal/extractor_tests.json")).as_a
    checked = 0
    suites.each do |suite|
      key = suite.as_h["key"].as_s
      suite.as_h["tests"].as_a.each_with_index do |test, index|
        info = test.as_h["info_dict"]?
        next unless info
        ExtractorFixtureMatcher.validate!(info, "#{key}[#{index}].info_dict")
        checked += 1
      end
    end
    checked.should be > 4_000
  end
end
