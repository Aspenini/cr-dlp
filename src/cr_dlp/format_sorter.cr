module CrDlp
  class FormatSorter
    DEFAULT_ORDER = %w[
      hidden aud_or_vid hasvid ie_pref lang quality res fps hdr:12 vcodec
      channels acodec size br asr proto ext hasaud source id
    ]
    FORCED_ORDER   = %w[hidden aud_or_vid]
    PRIORITY_ORDER = %w[hasvid ie_pref]

    ALIASES = {
      "format_id"            => "id",
      "preference"           => "ie_pref",
      "language_preference"  => "lang",
      "source_preference"    => "source",
      "protocol"             => "proto",
      "filesize_approx"      => "fs_approx",
      "audio_channels"       => "channels",
      "dimension"            => "res",
      "resolution"           => "res",
      "extension"            => "ext",
      "bitrate"              => "br",
      "total_bitrate"        => "tbr",
      "video_bitrate"        => "vbr",
      "audio_bitrate"        => "abr",
      "framerate"            => "fps",
      "filesize_estimate"    => "size",
      "samplerate"           => "asr",
      "video_ext"            => "vext",
      "audio_ext"            => "aext",
      "video_codec"          => "vcodec",
      "audio_codec"          => "acodec",
      "video"                => "hasvid",
      "has_video"            => "hasvid",
      "audio"                => "hasaud",
      "has_audio"            => "hasaud",
      "extractor"            => "ie_pref",
      "extractor_preference" => "ie_pref",
    }

    VCODEC_ORDER = Array(String?).new.concat([
      "av0?1", "vp0?9\\.0?2", "vp0?9", "[hx]265|he?vc?", "[hx]264|avc",
      "vp0?8", "mp4v|h263", "theora", "", nil, "none",
    ])
    ACODEC_ORDER = Array(String?).new.concat([
      "[af]lac", "wav|aiff", "opus", "vorbis|ogg", "aac", "mp?4a?", "mp3",
      "ac-?4", "e-?a?c-?3", "ac-?3", "dts", "", nil, "none",
    ])
    HDR_ORDER      = Array(String?).new.concat(["dv", "(hdr)?12", "(hdr)?10\\+", "(hdr)?10", "hlg", "", "sdr", nil])
    PROTOCOL_ORDER = Array(String?).new.concat([
      "(ht|f)tps", "(ht|f)tp$", "m3u8.*", ".*dash", "websocket_frag",
      "rtmpe?", "", "mms|rtsp", "ws|websocket", "f4",
    ])
    VIDEO_EXT_ORDER      = Array(String?).new.concat(["mp4", "mov", "webm", "flv", "", "none"])
    FREE_VIDEO_EXT_ORDER = Array(String?).new.concat(["webm", "mp4", "mov", "flv", "", "none"])
    AUDIO_EXT_ORDER      = Array(String?).new.concat(["m4a", "aac", "mp3", "ogg", "opus", "web[am]", "", "none"])
    FREE_AUDIO_EXT_ORDER = Array(String?).new.concat(["ogg", "opus", "web[am]", "mp3", "m4a", "aac", "", "none"])

    private record SortField,
      name : String,
      reverse : Bool = false,
      closest : Bool = false,
      limit : String? = nil

    private record Preference,
      category : Int32,
      number : Float64 = 0.0,
      text : String = "",
      tertiary : Float64 = 0.0,
      string_value : Bool = false

    def initialize(
      @user_fields = [] of String,
      @force = false,
      @prefer_free_formats = false,
    )
    end

    def sort_info!(info : Info) : Array(JSON::Any)
      formats = info.formats
      return formats if formats.empty?
      extractor_fields = info.array?("_format_sort_fields").try do |values|
        values.compact_map(&.as_s?)
      end || [] of String
      sorted = sort(formats, extractor_fields)
      info["formats"] = JSON::Any.new(sorted)
      sorted
    end

    def sort(
      formats : Array(JSON::Any),
      extractor_fields = [] of String,
    ) : Array(JSON::Any)
      fields = build_order(extractor_fields)
      formats.each_with_index.to_a.sort do |left, right|
        comparison = compare_formats(left[0].as_h, right[0].as_h, fields)
        comparison == 0 ? left[1] <=> right[1] : comparison
      end.map(&.[0])
    end

    private def build_order(extractor_fields : Array(String)) : Array(SortField)
      result = [] of SortField
      seen = Set(String).new
      values = FORCED_ORDER +
               (@force ? [] of String : PRIORITY_ORDER) +
               @user_fields +
               extractor_fields +
               DEFAULT_ORDER
      values.each do |value|
        parse_fields(value).each do |field|
          next if seen.includes?(field.name)
          seen << field.name
          result << field
        end
      end
      result
    end

    private def parse_fields(value : String) : Array(SortField)
      match = value.match(/\A\s*(\+)?([a-zA-Z0-9_]+)(?:([~:])(.*))?\s*\z/) ||
              raise UsageError.new("Invalid format sort string: #{value}")
      reverse = !match[1]?.nil?
      name = ALIASES[match[2]]? || match[2].downcase
      closest = match[3]? == "~"
      limit = match[4]?

      case name
      when "codec", "ext"
        names = name == "codec" ? %w[vcodec acodec] : %w[vext aext]
        limits = limit.try(&.split(':')) || [] of String
        names.map_with_index do |field, index|
          SortField.new(field, reverse, closest, limits[index]?)
        end
      else
        [SortField.new(name, reverse, closest, limit)]
      end
    end

    private def compare_formats(
      left : Hash(String, JSON::Any),
      right : Hash(String, JSON::Any),
      fields : Array(SortField),
    ) : Int32
      fields.each do |field|
        comparison = compare_preference(
          preference(left, field),
          preference(right, field),
        )
        return comparison unless comparison == 0
      end
      0
    end

    private def compare_preference(left : Preference, right : Preference) : Int32
      comparison = left.category <=> right.category
      return comparison unless comparison == 0
      if left.string_value || right.string_value
        comparison = left.text <=> right.text
      else
        comparison = compare_float(left.number, right.number)
      end
      return comparison unless comparison == 0
      compare_float(left.tertiary, right.tertiary)
    end

    private def compare_float(left : Float64, right : Float64) : Int32
      return -1 if left < right
      return 1 if left > right
      0
    end

    private def preference(
      format : Hash(String, JSON::Any),
      field : SortField,
    ) : Preference
      value = field_value(format, field.name)
      value = extractor_value(value, field.name)
      value = boolean_value(value, field.name)
      value = ordered_value(value, field.name)
      value ||= default_value(field.name)
      return Preference.new(-10) if value.nil?

      if number = numeric_value(value)
        return numeric_preference(number, field)
      end
      Preference.new(1, text: value.to_s, string_value: true)
    end

    private def numeric_preference(value : Float64, field : SortField) : Preference
      limit = field.limit.try { |text| limit_value(field.name, text) }
      if field.closest && limit
        Preference.new(
          0,
          -((value - limit).abs),
          tertiary: field.reverse ? value - limit : limit - value,
        )
      elsif !field.reverse && (limit.nil? || value <= limit)
        Preference.new(0, value)
      elsif limit.nil? || (field.reverse && value == limit) || value > limit
        Preference.new(0, -value)
      else
        Preference.new(-1, value)
      end
    end

    private def field_value(
      format : Hash(String, JSON::Any),
      field : String,
    ) : JSON::Any::Type
      case field
      when "aud_or_vid"
        (codec(format, "vcodec") != "none" || codec(format, "acodec") != "none") ? 1_i64 : 0_i64
      when "hasvid"
        codec(format, "vcodec")
      when "hasaud"
        codec(format, "acodec")
      when "ie_pref", "hidden"
        raw_value(format, "preference")
      when "lang"
        raw_value(format, "language_preference")
      when "source"
        raw_value(format, "source_preference")
      when "proto"
        raw_value(format, "protocol") || protocol(format)
      when "vext"
        has_video?(format) ? extension(format) : "none"
      when "aext"
        !has_video?(format) && has_audio?(format) ? extension(format) : "none"
      when "hdr"
        raw_value(format, "dynamic_range")
      when "channels"
        raw_value(format, "audio_channels")
      when "id"
        raw_value(format, "format_id")
      when "res"
        [number(format, "height"), number(format, "width")].compact.reject(&.zero?).min? || 0.0
      when "size"
        first_nonzero(format, "filesize", "filesize_approx")
      when "br"
        first_nonzero(format, "tbr", "vbr", "abr")
      when "fs_approx"
        raw_value(format, "filesize_approx")
      when "vcodec", "acodec"
        raw_value(format, field)
      when "vbr"
        bitrate(format, "vbr", "abr", video: true)
      when "abr"
        bitrate(format, "abr", "vbr", video: false)
      when "tbr"
        total_bitrate(format)
      else
        raw_value(format, field)
      end
    end

    private def extractor_value(value : JSON::Any::Type, field : String) : JSON::Any::Type
      return value unless field.in?("hidden", "ie_pref")
      number = numeric_value(value)
      maximum = field == "hidden" ? -1000.0 : nil
      return -1.0 if number.nil? || (maximum && number >= maximum)
      number
    end

    private def boolean_value(value : JSON::Any::Type, field : String) : JSON::Any::Type
      return value unless field.in?("hasvid", "hasaud")
      value != "none" ? 0_i64 : -1_i64
    end

    private def ordered_value(value : JSON::Any::Type, field : String) : JSON::Any::Type
      settings = order_for(field)
      return value unless settings
      order, regex = settings
      ordered_rank(value.try(&.to_s), order, regex)
    end

    private def order_for(field : String) : Tuple(Array(String?), Bool)?
      case field
      when "vcodec" then {VCODEC_ORDER, true}
      when "acodec" then {ACODEC_ORDER, true}
      when "hdr"    then {HDR_ORDER, true}
      when "proto"  then {PROTOCOL_ORDER, true}
      when "vext"
        {@prefer_free_formats ? FREE_VIDEO_EXT_ORDER : VIDEO_EXT_ORDER, false}
      when "aext"
        {@prefer_free_formats ? FREE_AUDIO_EXT_ORDER : AUDIO_EXT_ORDER, true}
      end
    end

    private def ordered_rank(
      value : String?,
      order : Array(String?),
      regex : Bool,
    ) : Float64
      empty_index = order.index("") || order.size + 1
      if regex && value
        index = order.index do |pattern|
          pattern && !pattern.empty? && Regex.new("\\A(?:#{pattern})", Regex::Options::IGNORE_CASE).matches?(value)
        end
        return (order.size - (index || empty_index)).to_f64
      end
      index = order.index(value) || empty_index
      (order.size - index).to_f64
    end

    private def default_value(field : String) : JSON::Any::Type
      field.in?("lang", "quality", "source") ? -1.0 : nil
    end

    private def limit_value(field : String, value : String) : Float64?
      if order = order_for(field)
        return ordered_rank(value.downcase, order[0], order[1])
      end
      if field.in?("filesize", "fs_approx", "size")
        return parse_filesize(value)
      end
      value.to_f64?
    end

    private def parse_filesize(value : String) : Float64?
      return value.to_f64? if value.matches?(/\A[0-9.]+\z/)
      match = value.match(/\A([0-9.]+)([kKmMgGtTpPeEzZyY])(i)?[Bb]?\z/)
      return unless match
      exponent = "kmgtpezy".index(match[2].downcase).not_nil! + 1
      base = match[3]? ? 1024_f64 : 1000_f64
      match[1].to_f64 * (base ** exponent)
    end

    private def raw_value(format : Hash(String, JSON::Any), key : String) : JSON::Any::Type
      format[key]?.try(&.raw)
    end

    private def numeric_value(value : JSON::Any::Type) : Float64?
      case value
      when Int64   then value.to_f64
      when Float64 then value
      when String  then value.to_f64?
      when Bool    then value ? 1.0 : 0.0
      end
    end

    private def number(format : Hash(String, JSON::Any), key : String) : Float64?
      numeric_value(raw_value(format, key))
    end

    private def first_nonzero(
      format : Hash(String, JSON::Any),
      *keys : String,
    ) : JSON::Any::Type
      keys.each do |key|
        value = raw_value(format, key)
        number = numeric_value(value)
        return value unless value.nil? || number.try(&.zero?)
      end
      nil
    end

    private def codec(format : Hash(String, JSON::Any), key : String) : String?
      format[key]?.try(&.as_s?)
    end

    private def has_video?(format : Hash(String, JSON::Any)) : Bool
      codec(format, "vcodec") != "none"
    end

    private def has_audio?(format : Hash(String, JSON::Any)) : Bool
      codec(format, "acodec") != "none"
    end

    private def extension(format : Hash(String, JSON::Any)) : String
      format["ext"]?.try(&.as_s?) ||
        format["url"]?.try(&.as_s?).try do |url|
          Path.new(URI.parse(url).path).extension.lstrip('.').downcase
        end || ""
    rescue URI::Error
      ""
    end

    private def protocol(format : Hash(String, JSON::Any)) : String?
      format["url"]?.try(&.as_s?).try { |url| URI.parse(url).scheme }
    rescue URI::Error
      nil
    end

    private def bitrate(
      format : Hash(String, JSON::Any),
      key : String,
      other : String,
      video : Bool,
    ) : Float64?
      return 0.0 if video ? !has_video?(format) : !has_audio?(format)
      value = number(format, key)
      return value if value && value != 0
      total = number(format, "tbr")
      counterpart = number(format, other)
      total && counterpart ? total - counterpart : nil
    end

    private def total_bitrate(format : Hash(String, JSON::Any)) : Float64?
      value = number(format, "tbr")
      return value if value && value != 0
      video = bitrate(format, "vbr", "abr", video: true)
      audio = bitrate(format, "abr", "vbr", video: false)
      video && audio ? video + audio : nil
    end
  end
end
