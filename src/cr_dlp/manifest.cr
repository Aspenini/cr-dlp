require "openssl/cipher"
require "xml"

module CrDlp
  module Manifest
    extend self

    def resolve_url(base_url : String, reference : String) : String
      URI.parse(base_url).resolve(reference).to_s
    rescue URI::Error
      reference
    end

    def extension(url : String, fallback = "unknown_video") : String
      suffix = Path.new(URI.parse(url).path).extension.lstrip('.').downcase
      suffix.empty? ? fallback : suffix
    rescue URI::Error
      fallback
    end

    module Hls
      record ByteRange, start : Int64, finish : Int64 do
        def header : String
          "bytes=#{start}-#{finish - 1}"
        end
      end

      record Encryption,
        method : String,
        key_url : String?,
        iv : Bytes?

      record Fragment,
        url : String,
        duration : Float64?,
        byte_range : ByteRange?,
        media_sequence : Int64,
        encryption : Encryption?,
        initialization : Bool = false

      record Variant,
        url : String,
        format_id : String,
        bandwidth : Int64?,
        average_bandwidth : Int64?,
        width : Int32?,
        height : Int32?,
        fps : Float64?,
        codecs : Array(String),
        audio_group : String?,
        video_group : String? do
        def effective_bandwidth : Int64
          average_bandwidth || bandwidth || 0_i64
        end

        def video_codec : String?
          codecs.find { |codec| Codec.video?(codec) }
        end

        def audio_codec : String?
          codecs.find { |codec| Codec.audio?(codec) }
        end

        def audio_only? : Bool
          video_codec.nil? && !audio_codec.nil?
        end
      end

      record Rendition,
        media_type : String,
        group_id : String,
        name : String,
        url : String?,
        language : String?,
        default : Bool,
        autoselect : Bool,
        forced : Bool

      class Playlist
        getter url : String
        getter variants : Array(Variant)
        getter renditions : Array(Rendition)
        getter fragments : Array(Fragment)
        getter media : Bool
        getter end_list : Bool
        getter target_duration : Float64?

        def initialize(
          @url : String,
          @variants = [] of Variant,
          @renditions = [] of Rendition,
          @fragments = [] of Fragment,
          @media = false,
          @end_list = false,
          @target_duration = nil,
        )
        end

        def best_variant : Variant?
          @variants.max_by? do |variant|
            {
              variant.audio_only? ? 0 : 1,
              variant.effective_bandwidth,
              (variant.width || 0) * (variant.height || 0),
            }
          end
        end

        def subtitles : Hash(String, Array(Hash(String, JSON::Any)))
          result = Hash(String, Array(Hash(String, JSON::Any))).new do |hash, key|
            hash[key] = [] of Hash(String, JSON::Any)
          end
          @renditions.each do |rendition|
            next unless rendition.media_type == "SUBTITLES"
            next unless url = rendition.url
            item = {
              "url" => JSON::Any.new(url),
              "ext" => JSON::Any.new(Manifest.extension(url) == "m3u8" ? "vtt" : Manifest.extension(url)),
            }
            item["protocol"] = JSON::Any.new("m3u8_native") if Manifest.extension(url) == "m3u8"
            result[rendition.language || "und"] << item
          end
          result
        end
      end

      module Codec
        extend self

        VIDEO_PREFIXES = {"avc", "hev", "hvc", "vp", "av01", "theora"}
        AUDIO_PREFIXES = {"mp4a", "ac-3", "ec-3", "opus", "vorbis", "aac", "mp3"}

        def video?(codec : String) : Bool
          VIDEO_PREFIXES.any? { |prefix| codec.downcase.starts_with?(prefix) }
        end

        def audio?(codec : String) : Bool
          AUDIO_PREFIXES.any? { |prefix| codec.downcase.starts_with?(prefix) }
        end
      end

      module Attributes
        extend self

        def parse(source : String) : Hash(String, String)
          result = Hash(String, String).new
          index = 0
          while index < source.size
            while index < source.size && (source[index].whitespace? || source[index] == ',')
              index += 1
            end
            break if index >= source.size

            key_start = index
            while index < source.size && source[index] != '=' && source[index] != ','
              index += 1
            end
            key = source[key_start...index].strip
            if index >= source.size || source[index] != '='
              result[key] = ""
              next
            end
            index += 1

            value = if index < source.size && source[index] == '"'
                      index += 1
                      builder = String::Builder.new
                      escaped = false
                      while index < source.size
                        char = source[index]
                        index += 1
                        if escaped
                          builder << char
                          escaped = false
                        elsif char == '\\'
                          escaped = true
                        elsif char == '"'
                          break
                        else
                          builder << char
                        end
                      end
                      builder.to_s
                    else
                      value_start = index
                      while index < source.size && source[index] != ','
                        index += 1
                      end
                      source[value_start...index].strip
                    end
            result[key] = value
            while index < source.size && source[index] != ','
              index += 1
            end
          end
          result
        end
      end

      module Parser
        extend self

        def parse(document : String, url : String) : Playlist
          raise ExtractorError.new("Response data has no m3u header") unless document.lstrip.starts_with?("#EXTM3U")
          document.includes?("#EXT-X-TARGETDURATION") ? parse_media(document, url) : parse_master(document, url)
        end

        def parse_master(document : String, url : String) : Playlist
          variants = [] of Variant
          renditions = [] of Rendition
          pending = nil.as(Hash(String, String)?)

          document.each_line do |raw_line|
            line = raw_line.strip
            if line.starts_with?("#EXT-X-MEDIA:")
              attributes = Attributes.parse(line[13..])
              media_type = attributes["TYPE"]?
              group_id = attributes["GROUP-ID"]?
              name = attributes["NAME"]?
              next unless media_type && group_id && name
              renditions << Rendition.new(
                media_type,
                group_id,
                name,
                attributes["URI"]?.try { |reference| Manifest.resolve_url(url, reference) },
                attributes["LANGUAGE"]?,
                attributes["DEFAULT"]? == "YES",
                attributes["AUTOSELECT"]? == "YES",
                attributes["FORCED"]? == "YES",
              )
            elsif line.starts_with?("#EXT-X-STREAM-INF:")
              pending = Attributes.parse(line[18..])
            elsif !line.empty? && !line.starts_with?('#') && (attributes = pending)
              variants << build_variant(attributes, Manifest.resolve_url(url, line), variants.size)
              pending = nil
            end
          end
          Playlist.new(url, variants: variants, renditions: renditions)
        end

        def parse_media(document : String, url : String) : Playlist
          fragments = [] of Fragment
          duration = nil.as(Float64?)
          byte_range = nil.as(ByteRange?)
          byte_range_offset = 0_i64
          media_sequence = 0_i64
          encryption = nil.as(Encryption?)
          target_duration = nil.as(Float64?)
          end_list = false

          document.each_line do |raw_line|
            line = raw_line.strip
            next if line.empty?

            if line.starts_with?("#EXTINF:")
              duration = line[8..].partition(',')[0].to_f64?
            elsif line.starts_with?("#EXT-X-TARGETDURATION:")
              target_duration = line[22..].to_f64?
            elsif line.starts_with?("#EXT-X-MEDIA-SEQUENCE:")
              media_sequence = line[22..].to_i64
            elsif line.starts_with?("#EXT-X-BYTERANGE:")
              byte_range = parse_byte_range(line[17..], byte_range_offset)
            elsif line.starts_with?("#EXT-X-MAP:")
              attributes = Attributes.parse(line[11..])
              if reference = attributes["URI"]?
                map_range = attributes["BYTERANGE"]?.try { |value| parse_byte_range(value, 0_i64) }
                fragments << Fragment.new(
                  Manifest.resolve_url(url, reference),
                  nil,
                  map_range,
                  media_sequence,
                  encryption,
                  initialization: true,
                )
              end
            elsif line.starts_with?("#EXT-X-KEY:")
              encryption = parse_encryption(Attributes.parse(line[11..]), url)
            elsif line == "#EXT-X-ENDLIST"
              end_list = true
            elsif !line.starts_with?('#')
              fragments << Fragment.new(
                Manifest.resolve_url(url, line),
                duration,
                byte_range,
                media_sequence,
                encryption,
              )
              if range = byte_range
                byte_range_offset = range.finish
              end
              media_sequence += 1
              duration = nil
              byte_range = nil
            end
          end

          Playlist.new(
            url,
            fragments: fragments,
            media: true,
            end_list: end_list,
            target_duration: target_duration,
          )
        end

        private def build_variant(
          attributes : Hash(String, String),
          url : String,
          fallback_index : Int32,
        ) : Variant
          bandwidth = attributes["BANDWIDTH"]?.try(&.to_i64?)
          average = attributes["AVERAGE-BANDWIDTH"]?.try(&.to_i64?)
          width, height = parse_resolution(attributes["RESOLUTION"]?)
          effective = average || bandwidth
          Variant.new(
            url,
            effective ? (effective / 1000).to_i.to_s : fallback_index.to_s,
            bandwidth,
            average,
            width,
            height,
            attributes["FRAME-RATE"]?.try(&.to_f64?),
            attributes["CODECS"]?.try { |value| value.split(',').map(&.strip) } || [] of String,
            attributes["AUDIO"]?,
            attributes["VIDEO"]?,
          )
        end

        private def parse_resolution(value : String?) : Tuple(Int32?, Int32?)
          return {nil, nil} unless value
          match = value.match(/\A(\d+)[xX](\d+)\z/)
          match ? {match[1].to_i, match[2].to_i} : {nil, nil}
        end

        private def parse_byte_range(value : String, fallback_start : Int64) : ByteRange
          length, separator, offset = value.partition('@')
          start = separator.empty? ? fallback_start : offset.to_i64
          ByteRange.new(start, start + length.to_i64)
        end

        private def parse_encryption(attributes : Hash(String, String), url : String) : Encryption?
          method = attributes["METHOD"]? || "NONE"
          return nil if method == "NONE"
          iv = attributes["IV"]?.try { |value| hex_bytes(value.lchop("0x").rjust(32, '0')) }
          Encryption.new(
            method,
            attributes["URI"]?.try { |reference| Manifest.resolve_url(url, reference) },
            iv,
          )
        end

        private def hex_bytes(value : String) : Bytes
          raise ExtractorError.new("Invalid HLS hexadecimal value") unless value.size.even?
          Bytes.new(value.size // 2) do |index|
            value[index * 2, 2].to_u8(16)
          end
        end
      end

      def self.variant_info(
        variant : Variant,
        manifest_url : String,
        audio_groups_with_uri : Set(String),
      ) : Hash(String, JSON::Any)
        result = {
          "format_id"    => JSON::Any.new(variant.format_id),
          "url"          => JSON::Any.new(variant.url),
          "manifest_url" => JSON::Any.new(manifest_url),
          "ext"          => JSON::Any.new("mp4"),
          "protocol"     => JSON::Any.new("m3u8_native"),
        }
        result["tbr"] = JSON::Any.new(variant.effective_bandwidth.to_f64 / 1000) if variant.effective_bandwidth > 0
        result["width"] = JSON::Any.new(variant.width.not_nil!.to_i64) if variant.width
        result["height"] = JSON::Any.new(variant.height.not_nil!.to_i64) if variant.height
        result["fps"] = JSON::Any.new(variant.fps.not_nil!) if variant.fps
        if video = variant.video_codec
          result["vcodec"] = JSON::Any.new(video)
        elsif variant.audio_codec
          result["vcodec"] = JSON::Any.new("none")
        end
        if audio = variant.audio_codec
          result["acodec"] = JSON::Any.new(audio)
        end
        if group = variant.audio_group
          result["acodec"] = JSON::Any.new("none") if audio_groups_with_uri.includes?(group) && variant.video_codec
        end
        result
      end
    end

    module Dash
      record Fragment, url : String, byte_range : String? = nil do
        def to_info : JSON::Any
          result = {"url" => JSON::Any.new(url)}
          result["range"] = JSON::Any.new(byte_range.not_nil!) if byte_range
          JSON::Any.new(result)
        end
      end

      class Representation
        getter id : String
        getter url : String
        getter manifest_url : String
        getter ext : String
        getter mime_type : String?
        getter codecs : Array(String)
        getter bandwidth : Int64?
        getter width : Int32?
        getter height : Int32?
        getter fps : Float64?
        getter asr : Int32?
        getter fragments : Array(Fragment)
        getter content_type : String
        getter language : String?
        getter dynamic : Bool
        getter minimum_update_period : Float64?

        def initialize(
          @id : String,
          @url : String,
          @manifest_url : String,
          @ext : String,
          @mime_type : String?,
          @codecs : Array(String),
          @bandwidth : Int64?,
          @width : Int32?,
          @height : Int32?,
          @fps : Float64?,
          @asr : Int32?,
          @fragments : Array(Fragment),
          @content_type : String,
          @language : String?,
          @dynamic = false,
          @minimum_update_period = nil,
        )
        end

        def fragmented? : Bool
          !@fragments.empty?
        end

        def video? : Bool
          @content_type == "video" || @codecs.any? { |codec| Hls::Codec.video?(codec) }
        end

        def subtitle? : Bool
          @content_type == "text" || @mime_type.try(&.starts_with?("text/")) == true
        end

        def score
          {
            video? ? 1 : 0,
            (@width || 0) * (@height || 0),
            @bandwidth || 0_i64,
          }
        end

        def to_info(include_fragments = false) : Hash(String, JSON::Any)
          result = {
            "format_id"    => JSON::Any.new(@id),
            "url"          => JSON::Any.new(fragmented? ? @manifest_url : @url),
            "manifest_url" => JSON::Any.new(@manifest_url),
            "ext"          => JSON::Any.new(@ext),
            "protocol"     => JSON::Any.new(fragmented? ? "http_dash_segments" : URI.parse(@url).scheme.presence || "http"),
          }
          result["tbr"] = JSON::Any.new(@bandwidth.not_nil!.to_f64 / 1000) if @bandwidth
          result["width"] = JSON::Any.new(@width.not_nil!.to_i64) if @width
          result["height"] = JSON::Any.new(@height.not_nil!.to_i64) if @height
          result["fps"] = JSON::Any.new(@fps.not_nil!) if @fps
          result["asr"] = JSON::Any.new(@asr.not_nil!.to_i64) if @asr

          video_codec = @codecs.find { |codec| Hls::Codec.video?(codec) }
          audio_codec = @codecs.find { |codec| Hls::Codec.audio?(codec) }
          result["vcodec"] = JSON::Any.new(video_codec || "none")
          result["acodec"] = JSON::Any.new(audio_codec || "none")
          result["fragments"] = JSON::Any.new(@fragments.map(&.to_info)) if include_fragments && fragmented?
          result["is_live"] = JSON::Any.new(true) if @dynamic
          result
        end
      end

      class Presentation
        getter representations : Array(Representation)
        getter dynamic : Bool
        getter minimum_update_period : Float64?

        def initialize(
          @representations : Array(Representation),
          @dynamic = false,
          @minimum_update_period = nil,
        )
        end

        def formats : Array(Representation)
          @representations.reject(&.subtitle?)
        end

        def best_representation : Representation?
          formats.max_by?(&.score)
        end

        def subtitles : Hash(String, Array(Hash(String, JSON::Any)))
          result = Hash(String, Array(Hash(String, JSON::Any))).new do |hash, language|
            hash[language] = [] of Hash(String, JSON::Any)
          end
          @representations.each do |representation|
            next unless representation.subtitle?
            result[representation.language || "und"] << representation.to_info(include_fragments: true)
          end
          result
        end
      end

      class PresentationSidecar < SidecarValue
        getter presentation : Presentation

        def initialize(@presentation : Presentation)
        end
      end

      module Parser
        extend self

        def parse(document : String, url : String) : Presentation
          xml = XML.parse(document)
          mpd = xml.xpath_node("/*[local-name()='MPD']") ||
                raise ExtractorError.new("Response data is not a DASH MPD")

          dynamic = mpd["type"]? == "dynamic"
          duration = parse_duration(mpd["mediaPresentationDuration"]?)
          minimum_update_period = parse_duration(mpd["minimumUpdatePeriod"]?)
          availability_start = parse_time(mpd["availabilityStartTime"]?)
          publish_time = parse_time(mpd["publishTime"]?) || Time.utc
          time_shift_buffer = parse_duration(mpd["timeShiftBufferDepth"]?)
          root_base = resolve_base(url, mpd)
          representations = [] of Representation
          mpd.xpath_nodes("./*[local-name()='Period']").each do |period|
            period_duration = parse_duration(period["duration"]?) || duration
            period_start = parse_duration(period["start"]?) || 0.0
            live_edge = if dynamic && availability_start
                          Math.max(0.0, (publish_time - availability_start).total_seconds - period_start)
                        end
            period_base = resolve_base(root_base, period)
            period.xpath_nodes("./*[local-name()='AdaptationSet']").each do |adaptation|
              adaptation_base = resolve_base(period_base, adaptation)
              adaptation.xpath_nodes("./*[local-name()='Representation']").each do |node|
                representations << parse_representation(
                  node,
                  adaptation,
                  adaptation_base,
                  url,
                  period_duration,
                  dynamic,
                  minimum_update_period,
                  live_edge,
                  time_shift_buffer,
                )
              end
            end
          end
          raise ExtractorError.new("DASH manifest has no representations") if representations.empty?
          Presentation.new(representations, dynamic, minimum_update_period)
        rescue error : XML::Error
          raise ExtractorError.new("Unable to parse DASH manifest: #{error.message}", cause: error)
        end

        private def parse_representation(
          node : XML::Node,
          adaptation : XML::Node,
          base_url : String,
          manifest_url : String,
          duration : Float64?,
          dynamic : Bool,
          minimum_update_period : Float64?,
          live_edge : Float64?,
          time_shift_buffer : Float64?,
        ) : Representation
          id = node["id"]? || node["bandwidth"]? || "dash"
          representation_base = resolve_base(base_url, node)
          mime_type = inherited(node, adaptation, "mimeType")
          codecs = (inherited(node, adaptation, "codecs") || "").split(',').map(&.strip).reject(&.empty?)
          content_type = inherited(node, adaptation, "contentType") || content_type(mime_type, codecs)
          segment_list = child(node, "SegmentList") || child(adaptation, "SegmentList")
          segment_template = child(node, "SegmentTemplate") || child(adaptation, "SegmentTemplate")
          segment_base = child(node, "SegmentBase") || child(adaptation, "SegmentBase")

          fragments = if segment_list
                        parse_segment_list(segment_list, representation_base)
                      elsif segment_template
                        parse_segment_template(
                          segment_template,
                          representation_base,
                          id,
                          node["bandwidth"]?,
                          duration,
                          dynamic,
                          live_edge,
                          time_shift_buffer,
                        )
                      else
                        [] of Fragment
                      end
          direct_url = segment_base || fragments.empty? ? representation_base : manifest_url
          Representation.new(
            id,
            direct_url,
            manifest_url,
            extension_for(mime_type, representation_base),
            mime_type,
            codecs,
            inherited(node, adaptation, "bandwidth").try(&.to_i64?),
            inherited(node, adaptation, "width").try(&.to_i32?),
            inherited(node, adaptation, "height").try(&.to_i32?),
            parse_frame_rate(inherited(node, adaptation, "frameRate")),
            inherited(node, adaptation, "audioSamplingRate").try(&.to_i32?),
            fragments,
            content_type,
            inherited(node, adaptation, "lang"),
            dynamic,
            minimum_update_period,
          )
        end

        private def parse_segment_list(node : XML::Node, base_url : String) : Array(Fragment)
          fragments = [] of Fragment
          if initialization = child(node, "Initialization")
            if source = initialization["sourceURL"]?
              fragments << Fragment.new(Manifest.resolve_url(base_url, source), initialization["range"]?)
            elsif range = initialization["range"]?
              fragments << Fragment.new(base_url, range)
            end
          end
          node.xpath_nodes("./*[local-name()='SegmentURL']").each do |segment|
            next unless media = segment["media"]?
            fragments << Fragment.new(Manifest.resolve_url(base_url, media), segment["mediaRange"]?)
          end
          fragments
        end

        private def parse_segment_template(
          node : XML::Node,
          base_url : String,
          id : String,
          bandwidth : String?,
          presentation_duration : Float64?,
          dynamic : Bool,
          live_edge : Float64?,
          time_shift_buffer : Float64?,
        ) : Array(Fragment)
          fragments = [] of Fragment
          if initialization = node["initialization"]?
            fragments << Fragment.new(Manifest.resolve_url(base_url, substitute(initialization, id, bandwidth, 0_i64, 0_i64)))
          end
          media = node["media"]? || return fragments
          timescale = node["timescale"]?.try(&.to_f64?) || 1.0
          start_number = node["startNumber"]?.try(&.to_i64?) || 1_i64
          if timeline = child(node, "SegmentTimeline")
            timeline_values(timeline, timescale, presentation_duration).each_with_index do |time, index|
              number = start_number + index
              reference = substitute(media, id, bandwidth, number, time)
              fragments << Fragment.new(Manifest.resolve_url(base_url, reference))
            end
          elsif segment_duration = node["duration"]?.try(&.to_f64?)
            if dynamic
              return fragments unless live_edge
              first_index = if time_shift_buffer
                              Math.max(0, ((live_edge - time_shift_buffer) * timescale / segment_duration).floor.to_i)
                            else
                              0
                            end
              last_index = (live_edge * timescale / segment_duration).floor.to_i - 1
              return fragments if last_index < first_index
            else
              return fragments unless presentation_duration
              first_index = 0
              last_index = (presentation_duration * timescale / segment_duration).ceil.to_i - 1
            end
            (first_index..last_index).each do |index|
              number = start_number + index
              reference = substitute(media, id, bandwidth, number, (index * segment_duration).to_i64)
              fragments << Fragment.new(Manifest.resolve_url(base_url, reference))
            end
          end
          fragments
        end

        private def timeline_values(
          timeline : XML::Node,
          timescale : Float64,
          presentation_duration : Float64?,
        ) : Array(Int64)
          nodes = timeline.xpath_nodes("./*[local-name()='S']").to_a
          values = [] of Int64
          current = 0_i64
          nodes.each_with_index do |node, index|
            current = node["t"]?.try(&.to_i64?) || current
            segment_duration = node["d"]?.try(&.to_i64?) ||
                               raise ExtractorError.new("DASH SegmentTimeline entry is missing duration")
            repeat = node["r"]?.try(&.to_i?) || 0
            if repeat < 0
              boundary = nodes[index + 1]?.try { |next_node| next_node["t"]?.try(&.to_i64?) }
              boundary ||= (presentation_duration.try { |value| (value * timescale).to_i64 })
              repeat = boundary ? Math.max(0, ((boundary - current) // segment_duration - 1).to_i) : 0
            end
            (repeat + 1).times do
              values << current
              current += segment_duration
            end
          end
          values
        end

        private def substitute(
          template : String,
          id : String,
          bandwidth : String?,
          number : Int64,
          time : Int64,
        ) : String
          result = template
            .gsub("$RepresentationID$", id)
            .gsub("$Bandwidth$", bandwidth || "")
            .gsub("$Number$", number.to_s)
            .gsub("$Time$", time.to_s)
          result = result.gsub(/\$Number%0(\d+)d\$/) do |token|
            width = token.match(/\d+/).not_nil![0].to_i
            number.to_s.rjust(width, '0')
          end
          result.gsub(/\$Time%0(\d+)d\$/) do |token|
            width = token.match(/\d+/).not_nil![0].to_i
            time.to_s.rjust(width, '0')
          end
        end

        private def resolve_base(base_url : String, node : XML::Node) : String
          reference = child(node, "BaseURL").try(&.content.strip)
          reference && !reference.empty? ? Manifest.resolve_url(base_url, reference) : base_url
        end

        private def child(node : XML::Node, name : String) : XML::Node?
          node.xpath_node("./*[local-name()='#{name}']")
        end

        private def inherited(node : XML::Node, parent : XML::Node, name : String) : String?
          node[name]? || parent[name]?
        end

        private def content_type(mime_type : String?, codecs : Array(String)) : String
          return mime_type.not_nil!.partition('/')[0] if mime_type
          return "video" if codecs.any? { |codec| Hls::Codec.video?(codec) }
          return "audio" if codecs.any? { |codec| Hls::Codec.audio?(codec) }
          "unknown"
        end

        private def extension_for(mime_type : String?, url : String) : String
          case mime_type
          when "audio/mp4"                    then "m4a"
          when "video/mp4", "application/mp4" then "mp4"
          when "audio/webm", "video/webm"     then "webm"
          when "text/vtt"                     then "vtt"
          when "application/ttml+xml"         then "ttml"
          else
            Manifest.extension(url)
          end
        end

        private def parse_frame_rate(value : String?) : Float64?
          return unless value
          numerator, separator, denominator = value.partition('/')
          return numerator.to_f64? if separator.empty?
          denominator_value = denominator.to_f64?
          denominator_value && denominator_value != 0 ? numerator.to_f64 / denominator_value : nil
        end

        private def parse_duration(value : String?) : Float64?
          return unless value
          match = value.match(/\AP(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?\z/)
          return unless match
          (match[1]?.try(&.to_f64) || 0.0) * 86_400 +
            (match[2]?.try(&.to_f64) || 0.0) * 3_600 +
            (match[3]?.try(&.to_f64) || 0.0) * 60 +
            (match[4]?.try(&.to_f64) || 0.0)
        end

        private def parse_time(value : String?) : Time?
          return unless value
          Time.parse_rfc3339(value)
        rescue Time::Format::Error
          nil
        end
      end
    end
  end
end
