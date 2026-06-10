module CrDlp
  alias FormatAvailabilityChecker = Proc(Hash(String, JSON::Any), Bool)

  class FormatSelections < SidecarValue
    getter infos : Array(Info)

    def initialize(@infos : Array(Info))
    end
  end

  module FormatSelector
    extend self

    SUPPORTED_MERGE_EXTENSIONS = %w[avi flv mkv mov mp4 webm]
    AUDIO_EXTENSIONS           = %w[aac alac flac m4a mka mp3 oga ogg opus wav wma]
    VIDEO_EXTENSIONS           = %w[3gp asf avi flv m4v mkv mov mp4 mpeg mpg ogv ts webm]

    private abstract class SelectorNode
      getter filters = [] of String
    end

    private class AtomNode < SelectorNode
      getter name : String

      def initialize(@name : String)
      end
    end

    private class ListNode < SelectorNode
      getter items : Array(SelectorNode)

      def initialize(@items : Array(SelectorNode))
      end
    end

    private class ChoiceNode < SelectorNode
      getter choices : Array(SelectorNode)

      def initialize(@choices : Array(SelectorNode))
      end
    end

    private class MergeNode < SelectorNode
      getter left : SelectorNode
      getter right : SelectorNode

      def initialize(@left : SelectorNode, @right : SelectorNode)
      end
    end

    private record SelectionContext,
      formats : Array(JSON::Any),
      incomplete_formats : Bool,
      has_merged_format : Bool,
      availability : FormatAvailabilityChecker?

    private class Parser
      @index = 0

      def initialize(@source : String)
      end

      def parse : SelectorNode
        node = parse_list
        skip_whitespace
        syntax_error("unexpected token") unless eof?
        node
      end

      private def parse_list : SelectorNode
        items = [parse_choice] of SelectorNode
        while consume(',')
          items << parse_choice
        end
        items.size == 1 ? items.first : ListNode.new(items)
      end

      private def parse_choice : SelectorNode
        choices = [parse_merge] of SelectorNode
        while consume('/')
          choices << parse_merge
        end
        choices.size == 1 ? choices.first : ChoiceNode.new(choices)
      end

      private def parse_merge : SelectorNode
        node = parse_primary
        while consume('+')
          node = MergeNode.new(node, parse_primary)
        end
        node
      end

      private def parse_primary : SelectorNode
        skip_whitespace
        node = if consume('(')
                 grouped = parse_list
                 syntax_error("missing closing parenthesis") unless consume(')')
                 grouped
               else
                 name = read_atom
                 if name.empty? && current_byte == '['.ord
                   AtomNode.new("best")
                 elsif name.empty?
                   syntax_error("expected a format selector")
                 else
                   AtomNode.new(name)
                 end
               end

        while current_byte == '['.ord
          node.filters << read_filter
          skip_whitespace
        end
        node
      end

      private def read_atom : String
        skip_whitespace
        start = @index
        until eof?
          byte = current_byte
          break if byte.nil? || byte.chr.ascii_whitespace? || byte.in?(
                     '/'.ord, '+'.ord, ','.ord, '('.ord, ')'.ord, '['.ord, ']'.ord)
          @index += 1
        end
        @source.byte_slice(start, @index - start)
      end

      private def read_filter : String
        @index += 1
        start = @index
        quote : UInt8? = nil
        escaped = false
        until eof?
          byte = current_byte.not_nil!
          if escaped
            escaped = false
          elsif byte == '\\'.ord
            escaped = true
          elsif quote
            quote = nil if byte == quote
          elsif byte.in?('"'.ord, '\''.ord)
            quote = byte
          elsif byte == ']'.ord
            value = @source.byte_slice(start, @index - start)
            @index += 1
            syntax_error("empty format filter") if value.strip.empty?
            return value
          end
          @index += 1
        end
        syntax_error("missing closing bracket")
      end

      private def consume(character : Char) : Bool
        skip_whitespace
        return false unless current_byte == character.ord
        @index += 1
        true
      end

      private def skip_whitespace
        while (byte = current_byte) && byte.chr.ascii_whitespace?
          @index += 1
        end
      end

      private def current_byte : UInt8?
        @source.byte_at?(@index)
      end

      private def eof? : Bool
        @index >= @source.bytesize
      end

      private def syntax_error(message : String) : NoReturn
        raise UsageError.new("Invalid format specification: #{message}\n\t#{@source}")
      end
    end

    def select!(
      info : Info,
      expression : String?,
      merge_output_format : String? = nil,
      allow_multiple_video_streams : Bool = false,
      allow_multiple_audio_streams : Bool = false,
      format_sort = [] of String,
      format_sort_force : Bool = false,
      prefer_free_formats : Bool = false,
      availability : FormatAvailabilityChecker? = nil,
    ) : Info
      selected = select_all(
        info,
        expression,
        merge_output_format,
        allow_multiple_video_streams,
        allow_multiple_audio_streams,
        format_sort,
        format_sort_force,
        prefer_free_formats,
        availability,
      )
      first = selected.first
      info.data.clear
      info.data.merge!(first.data)
      info.sidecar.clear
      info.sidecar.merge!(first.sidecar)
      info.sidecar["format_selections"] = FormatSelections.new(selected) if selected.size > 1
      info
    end

    def select_all(
      info : Info,
      expression : String?,
      merge_output_format : String? = nil,
      allow_multiple_video_streams : Bool = false,
      allow_multiple_audio_streams : Bool = false,
      format_sort = [] of String,
      format_sort_force : Bool = false,
      prefer_free_formats : Bool = false,
      availability : FormatAvailabilityChecker? = nil,
    ) : Array(Info)
      selector = expression.presence || "best"
      root = Parser.new(selector).parse
      formats = FormatSorter.new(
        format_sort,
        format_sort_force,
        prefer_free_formats,
      ).sort_info!(info)
      return [info] if formats.empty?

      context = SelectionContext.new(
        formats,
        formats.all? { |format| !has_video?(format.as_h) } ||
        formats.all? { |format| !has_audio?(format.as_h) },
        formats.any? { |format| has_video?(format.as_h) && has_audio?(format.as_h) },
        availability,
      )
      selections = evaluate(
        root,
        context,
        allow_multiple_video_streams,
        allow_multiple_audio_streams,
      )
      if selections.empty?
        raise ExtractorError.new("Requested format is not available: #{selector}", true)
      end

      selections.map do |selection|
        build_selected_info(info, selection, merge_output_format)
      end
    end

    private def evaluate(
      node : SelectorNode,
      context : SelectionContext,
      allow_multiple_video_streams : Bool,
      allow_multiple_audio_streams : Bool,
    ) : Array(Array(JSON::Any))
      filtered_context = SelectionContext.new(
        node.filters.reduce(context.formats) do |formats, filter|
          formats.select { |format| matches_filter?(format.as_h, filter) }
        end,
        context.incomplete_formats,
        context.has_merged_format,
        context.availability,
      )

      case node
      when AtomNode
        evaluate_atom(node.name, filtered_context, allow_multiple_video_streams, allow_multiple_audio_streams)
      when ListNode
        node.items.flat_map do |item|
          evaluate(item, filtered_context, allow_multiple_video_streams, allow_multiple_audio_streams)
        end
      when ChoiceNode
        node.choices.each do |choice|
          selected = evaluate(choice, filtered_context, allow_multiple_video_streams, allow_multiple_audio_streams)
          return selected unless selected.empty?
        end
        [] of Array(JSON::Any)
      when MergeNode
        left = evaluate(node.left, filtered_context, allow_multiple_video_streams, allow_multiple_audio_streams)
        right = evaluate(node.right, filtered_context, allow_multiple_video_streams, allow_multiple_audio_streams)
        left.flat_map do |left_formats|
          right.map do |right_formats|
            combine_formats(
              left_formats + right_formats,
              allow_multiple_video_streams,
              allow_multiple_audio_streams,
            )
          end
        end
      else
        [] of Array(JSON::Any)
      end
    end

    private def evaluate_atom(
      name : String,
      context : SelectionContext,
      allow_multiple_video_streams : Bool,
      allow_multiple_audio_streams : Bool,
    ) : Array(Array(JSON::Any))
      formats = context.formats
      case name
      when "all"
        return ranked(formats).reverse.compact_map do |format|
          [format] if available?(format, context)
        end
      when "mergeall"
        merged = combine_formats(
          ranked(formats.select do |format|
            playable?(format.as_h) && available?(format, context)
          end).reverse,
          allow_multiple_video_streams,
          allow_multiple_audio_streams,
        )
        return merged.empty? ? [] of Array(JSON::Any) : [merged]
      end

      if match = name.match(/\A(best|worst|b|w)(video|audio|v|a)?(\*)?(?:\.([1-9]\d*))?\z/)
        best = match[1].starts_with?('b')
        kind = match[2]?.try(&.[0])
        modified = !match[3]?.nil?
        index = (match[4]?.try(&.to_i) || 1) - 1
        candidates = formats.select do |format|
          values = format.as_h
          next false unless playable?(values)
          case kind
          when 'v'
            has_video?(values) && (modified || !has_audio?(values))
          when 'a'
            has_audio?(values) && (modified || !has_video?(values))
          else
            modified || (has_video?(values) && has_audio?(values))
          end
        end
        if candidates.empty? && kind.nil? && !modified && context.incomplete_formats
          candidates = formats.select { |format| playable?(format.as_h) }
        end
        ordered = ranked(candidates)
        ordered.reverse! if best
        working_index = 0
        ordered.each do |candidate|
          next unless available?(candidate, context)
          return [[candidate]] if working_index == index
          working_index += 1
        end
        return [] of Array(JSON::Any)
      end

      candidates = if AUDIO_EXTENSIONS.includes?(name)
                     formats.select do |format|
                       values = format.as_h
                       values["ext"]?.try(&.as_s?) == name && has_audio?(values)
                     end
                   elsif VIDEO_EXTENSIONS.includes?(name)
                     formats.select do |format|
                       values = format.as_h
                       values["ext"]?.try(&.as_s?) == name &&
                         has_video?(values) && has_audio?(values)
                     end
                   else
                     formats.select do |format|
                       format.as_h["format_id"]?.try(&.as_s?) == name
                     end
                   end
      ranked(candidates).reverse_each do |candidate|
        return [[candidate]] if available?(candidate, context)
      end
      [] of Array(JSON::Any)
    end

    private def available?(format : JSON::Any, context : SelectionContext) : Bool
      checker = context.availability
      checker.nil? || checker.call(format.as_h)
    end

    private def matches_filter?(
      format : Hash(String, JSON::Any),
      filter : String,
    ) : Bool
      if match = filter.match(/\A\s*([\w.-]+)\s*(<=|>=|!=|=|<|>)\s*(\?)?\s*([0-9.]+(?:[kKmMgGtTpPeEzZyY]i?[Bb]?)?)\s*\z/)
        actual = format[match[1]]?
        return !match[3]?.nil? if actual.nil? || actual.raw.nil?
        number = json_number(actual)
        return false unless number
        expected = parse_numeric_filter(match[4])
        return compare_numbers(number, expected, match[2])
      end

      if match = filter.match(/\A\s*([\w.-]+)\s*(!)?(\^=|\$=|\*=|~=|=)\s*(\?)?\s*(?:"((?:\\.|[^"])*)"|'((?:\\.|[^'])*)'|([\w.-]+))\s*\z/)
        value = format[match[1]]?
        return !match[4]?.nil? if value.nil? || value.raw.nil?
        actual = value.as_s?
        return false unless actual
        expected = unescape_filter_value(match[5]? || match[6]? || match[7])
        matched = case match[3]
                  when "="  then actual == expected
                  when "^=" then actual.starts_with?(expected)
                  when "$=" then actual.ends_with?(expected)
                  when "*=" then actual.includes?(expected)
                  when "~=" then Regex.new(expected).matches?(actual)
                  else           false
                  end
        return match[2]? ? !matched : matched
      end

      raise UsageError.new("Invalid filter specification: #{filter}")
    rescue error : Regex::Error
      raise UsageError.new("Invalid regular expression in format filter: #{filter}", cause: error)
    end

    private def parse_numeric_filter(value : String) : Float64
      return value.to_f64 if value.matches?(/\A[0-9.]+\z/)
      match = value.match(/\A([0-9.]+)([kKmMgGtTpPeEzZyY])(i)?[Bb]?\z/) ||
              raise UsageError.new("Invalid numeric value in format filter: #{value}")
      units = "kMGTPEZY"
      exponent = units.downcase.index(match[2].downcase).not_nil! + 1
      base = match[3]? ? 1024_f64 : 1000_f64
      match[1].to_f64 * (base ** exponent)
    rescue error : ArgumentError
      raise UsageError.new("Invalid numeric value in format filter: #{value}", cause: error)
    end

    private def compare_numbers(actual : Float64, expected : Float64, operator : String) : Bool
      case operator
      when "<"  then actual < expected
      when "<=" then actual <= expected
      when ">"  then actual > expected
      when ">=" then actual >= expected
      when "="  then actual == expected
      when "!=" then actual != expected
      else           false
      end
    end

    private def unescape_filter_value(value : String) : String
      value.gsub(/\\([\\"'])/, "\\1")
    end

    private def json_number(value : JSON::Any) : Float64?
      value.as_f? || value.as_i64?.try(&.to_f64)
    end

    private def ranked(formats : Array(JSON::Any)) : Array(JSON::Any)
      formats
    end

    private def combine_formats(
      formats : Array(JSON::Any),
      allow_multiple_video_streams : Bool,
      allow_multiple_audio_streams : Bool,
    ) : Array(JSON::Any)
      selected = [] of JSON::Any
      has_video = false
      has_audio = false
      formats.each do |format|
        values = format.as_h
        video = has_video?(values)
        audio = has_audio?(values)
        next if (!allow_multiple_video_streams && video && has_video) ||
                (!allow_multiple_audio_streams && audio && has_audio)
        selected << format
        has_video ||= video
        has_audio ||= audio
      end
      selected
    end

    private def playable?(format : Hash(String, JSON::Any)) : Bool
      has_video?(format) || has_audio?(format)
    end

    private def has_video?(format : Hash(String, JSON::Any)) : Bool
      format["vcodec"]?.try(&.as_s?) != "none"
    end

    private def has_audio?(format : Hash(String, JSON::Any)) : Bool
      format["acodec"]?.try(&.as_s?) != "none"
    end

    private def number(format : Hash(String, JSON::Any), key : String) : Float64
      value = format[key]?
      return 0.0 unless value
      json_number(value) || 0.0
    end

    private def build_selected_info(
      info : Info,
      selection : Array(JSON::Any),
      merge_output_format : String?,
    ) : Info
      result = info.dup
      resolved = selection.map { |format| resolved_format(info, format.as_h) }
      if resolved.size == 1
        result.merge!(resolved.first)
        return result
      end

      result["requested_formats"] = JSON::Any.new(
        resolved.map { |format| JSON::Any.new(format) }
      )
      result["format_id"] = resolved.compact_map { |format| format["format_id"]?.try(&.as_s?) }.join("+")
      result["format"] = resolved.compact_map { |format| format["format"]?.try(&.as_s?) }.join("+")
      result["protocol"] = resolved.compact_map do |format|
        format["protocol"]?.try(&.as_s?) ||
          format["url"]?.try(&.as_s?).try { |url| URI.parse(url).scheme }
      end.join("+")
      result["ext"] = merge_extension(resolved, merge_output_format)
      result["tbr"] = resolved.sum { |format| number(format, "tbr") }
      copy_unique_stream_fields(result, resolved)
      result
    end

    private def copy_unique_stream_fields(
      info : Info,
      formats : Array(Hash(String, JSON::Any)),
    )
      videos = formats.select { |format| has_video?(format) }
      audios = formats.select { |format| has_audio?(format) }
      if videos.size == 1
        %w[width height resolution fps dynamic_range vcodec vbr aspect_ratio].each do |key|
          info[key] = videos.first[key].not_nil! if videos.first[key]?
        end
      end
      if audios.size == 1
        %w[acodec abr asr audio_channels].each do |key|
          info[key] = audios.first[key].not_nil! if audios.first[key]?
        end
      end
    end

    private def resolved_format(
      info : Info,
      selected : Hash(String, JSON::Any),
    ) : Hash(String, JSON::Any)
      result = selected.dup
      format_id = result["format_id"]?.try(&.as_s?)
      return result unless format_id
      sidecar = info.sidecar["dash_presentation"]?.as?(Manifest::Dash::PresentationSidecar)
      return result unless sidecar
      representation = sidecar.presentation.formats.find(&.id.==(format_id))
      representation ? representation.to_info(include_fragments: true) : result
    end

    private def merge_extension(
      formats : Array(Hash(String, JSON::Any)),
      preference : String?,
    ) : String
      if preference
        preferred = preference.split('/').map(&.strip).find do |extension|
          SUPPORTED_MERGE_EXTENSIONS.includes?(extension)
        end
        return preferred if preferred
      end

      extensions = formats.compact_map { |format| format["ext"]?.try(&.as_s?) }.to_set
      return "webm" if extensions == Set{"webm"}
      return "mp4" if extensions.all? { |extension| extension.in?("mp4", "m4a") }
      "mkv"
    end
  end
end
