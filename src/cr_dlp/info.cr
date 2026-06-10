module CrDlp
  # Marker base class for runtime-only values that must never enter info JSON.
  abstract class SidecarValue
  end

  class Info
    getter data : Hash(String, JSON::Any)
    getter sidecar : Hash(String, SidecarValue)

    def initialize(
      @data = Hash(String, JSON::Any).new,
      @sidecar = Hash(String, SidecarValue).new,
    )
    end

    def self.parse(source : String) : self
      new(JSON.parse(source).as_h)
    end

    def [](key : String) : JSON::Any
      @data[key]
    end

    def []?(key : String) : JSON::Any?
      @data[key]?
    end

    def []=(key : String, value : JSON::Any)
      @data[key] = value
    end

    def []=(key : String, value : String)
      self[key] = JSON::Any.new(value)
    end

    def []=(key : String, value : Bool)
      self[key] = JSON::Any.new(value)
    end

    def []=(key : String, value : Int)
      self[key] = JSON::Any.new(value.to_i64)
    end

    def []=(key : String, value : Float)
      self[key] = JSON::Any.new(value.to_f64)
    end

    def []=(key : String, value : Nil)
      self[key] = JSON::Any.new(nil)
    end

    def has_key?(key : String) : Bool
      @data.has_key?(key)
    end

    def delete(key : String)
      @data.delete(key)
    end

    def string?(key : String) : String?
      @data[key]?.try(&.as_s?)
    end

    def bool?(key : String) : Bool?
      @data[key]?.try(&.as_bool?)
    end

    def int?(key : String) : Int64?
      @data[key]?.try(&.as_i64?)
    end

    def float?(key : String) : Float64?
      value = @data[key]?
      return unless value
      value.as_f? || value.as_i64?.try(&.to_f64)
    end

    def hash?(key : String) : Hash(String, JSON::Any)?
      @data[key]?.try(&.as_h?)
    end

    def array?(key : String) : Array(JSON::Any)?
      @data[key]?.try(&.as_a?)
    end

    def id : String
      string?("id") || raise ExtractorError.new("Extractor result is missing id")
    end

    def title : String
      string?("title") || raise ExtractorError.new("Extractor result is missing title")
    end

    def url : String
      string?("url") || raise ExtractorError.new("Extractor result is missing url")
    end

    def ext : String
      string?("ext") || "unknown_video"
    end

    def protocol : String
      string?("protocol") || URI.parse(url).scheme.presence || "http"
    end

    def formats : Array(JSON::Any)
      array?("formats") || [] of JSON::Any
    end

    def merge!(other : Hash(String, JSON::Any))
      other.each { |key, value| @data[key] = value }
      self
    end

    def dup : self
      Info.new(@data.dup, @sidecar.dup)
    end

    def to_json(json : JSON::Builder)
      @data.to_json(json)
    end

    def to_pretty_json : String
      JSON.build(indent: 2) { |json| to_json(json) }
    end
  end
end
