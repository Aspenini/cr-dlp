module CrDlp
  class OutputTemplate
    getter na_placeholder : String

    def initialize(
      @na_placeholder = "NA",
      @restrict_filenames = false,
      @windows_filenames : Bool? = nil,
      @trim_file_name = 0,
      @autonumber_start = 1_i64,
      @autonumber_size = 5,
    )
    end

    def render(
      template : String,
      info : Info,
      download_number = 1_i64,
      sanitize = true,
    ) : String
      values = generated_values(info, download_number)
      result = String.build do |output|
        index = 0
        while marker = template.index('%', index)
          output << template.byte_slice(index, marker - index)
          if template.byte_at?(marker + 1) == '%'.ord
            output << '%'
            index = marker + 2
            next
          end
          unless template.byte_at?(marker + 1) == '('.ord
            output << '%'
            index = marker + 1
            next
          end

          closing = template.index(')', marker + 2)
          unless closing
            output << template.byte_slice(marker, template.bytesize - marker)
            index = template.bytesize
            break
          end
          format_match = template.byte_slice(closing + 1, template.bytesize - closing - 1)
            .match(/\A([#0 +\-]*\d*(?:\.\d+)?)([a-zA-Z])/)
          unless format_match
            output << template.byte_slice(marker, closing - marker + 1)
            index = closing + 1
            next
          end

          key = template.byte_slice(marker + 2, closing - marker - 2)
          output << render_placeholder(key, format_match[1], format_match[2][0], values, sanitize)
          index = closing + 1 + format_match[0].bytesize
        end
        output << template.byte_slice(index, template.bytesize - index) if index < template.bytesize
      end
      trim_filename(result)
    end

    private def generated_values(info : Info, download_number : Int64) : Hash(String, JSON::Any)
      values = info.data.dup
      values["epoch"] ||= JSON::Any.new(Time.utc.to_unix)
      values["autonumber"] = JSON::Any.new(@autonumber_start - 1 + download_number)
      if duration = info.float?("duration")
        values["duration_string"] = JSON::Any.new(format_duration(duration))
      end
      unless values["resolution"]?
        if (width = info.int?("width")) && (height = info.int?("height"))
          values["resolution"] = JSON::Any.new("#{width}x#{height}")
        elsif height = info.int?("height")
          values["resolution"] = JSON::Any.new("#{height}p")
        elsif width = info.int?("width")
          values["resolution"] = JSON::Any.new("#{width}x?")
        end
      end
      values
    end

    private def render_placeholder(
      key : String,
      flags : String,
      type : Char,
      values : Hash(String, JSON::Any),
      sanitize : Bool,
    ) : String
      expression, default = split_once(key, '|')
      expression, replacement = split_once(expression, '&')
      value = split_unescaped(expression, ',').each do |alternative|
        resolved = evaluate(alternative, values)
        break resolved unless missing?(resolved)
      end
      value = nil unless value.is_a?(JSON::Any)

      if value && replacement
        replacement_value = scalar_string(value)
        value = JSON::Any.new(
          replacement.includes?("{}") ? replacement.gsub("{}", replacement_value) : replacement
        )
      end
      unless value
        fallback = default.nil? ? @na_placeholder : unescape(default)
        return "" if fallback.empty?
        return sanitize ? sanitize_value(key, fallback) : fallback
      end

      field = base_field(key)
      effective_flags = flags
      effective_type = type
      if type == 's' && numeric(value)
        width = compatibility_width(field, values)
        if width
          effective_flags = "0#{width}"
          effective_type = 'd'
        end
      end
      formatted = format_value(value, effective_flags, effective_type, field)
      unless formatted
        fallback = default.nil? ? @na_placeholder : unescape(default)
        return "" if fallback.empty?
        return sanitize ? sanitize_value(field, fallback) : fallback
      end
      formatted = formatted.gsub(':', '-') if sanitize && field == "duration_string"
      sanitize ? sanitize_value(field, formatted) : formatted
    rescue error : Error
      raise error
    rescue error
      raise UsageError.new("Invalid output template field #{key}: #{error.message}", cause: error)
    end

    private def evaluate(expression : String, values : Hash(String, JSON::Any)) : JSON::Any?
      source, date_format = split_once(expression, '>')
      value = evaluate_math(source, values)
      return unless value
      return value unless date_format
      number = numeric(value)
      return unless number
      JSON::Any.new(Time.unix(number.to_i64).to_utc.to_s(unescape(date_format)))
    rescue Time::Format::Error
      nil
    end

    private def evaluate_math(expression : String, values : Hash(String, JSON::Any)) : JSON::Any?
      source = expression.strip
      negate = source.starts_with?('-') && source.size > 1 && !source[1].number?
      source = source[1..] if negate
      operands, operators = split_math(source)
      value = lookup(values, operands.first)
      return unless value
      if operators.empty?
        if negate
          number = numeric(value)
          return number ? JSON::Any.new(-number) : nil
        end
        return value
      end

      result = numeric(value)
      return unless result
      operators.each_with_index do |operator, index|
        operand = numeric_literal(operands[index + 1]) ||
                  lookup(values, operands[index + 1]).try { |item| numeric(item) }
        return unless operand
        result = case operator
                 when '+' then result + operand
                 when '-' then result - operand
                 when '*' then result * operand
                 else          result
                 end
      end
      result = -result if negate
      JSON::Any.new(result)
    end

    private def split_math(source : String) : Tuple(Array(String), Array(Char))
      operands = [] of String
      operators = [] of Char
      start = 0
      source.each_char_with_index do |char, index|
        next unless index > 0 && char.in?('+', '-', '*')
        next if char == '-' && source[index - 1].in?('.', ':')
        operands << source[start...index]
        operators << char
        start = index + 1
      end
      operands << source[start..]
      {operands, operators}
    end

    private def lookup(values : Hash(String, JSON::Any), path : String) : JSON::Any?
      return JSON::Any.new(values) if path.empty?
      traverse(JSON::Any.new(values), path.split('.'), 0)
    end

    private def traverse(current : JSON::Any, tokens : Array(String), index : Int32) : JSON::Any?
      return current if index >= tokens.size
      token = tokens[index]
      case raw = current.raw
      when Hash
        value = current.as_h[token]?
        value ? traverse(value, tokens, index + 1) : nil
      when Array
        array = current.as_a
        if token.includes?(':')
          selected = slice(array, token)
          mapped = selected.compact_map { |item| traverse(item, tokens, index + 1) }
          JSON::Any.new(mapped)
        elsif position = token.to_i?
          position += array.size if position < 0
          value = array[position]?
          value ? traverse(value, tokens, index + 1) : nil
        end
      when String
        characters = raw.chars
        if token.includes?(':')
          selected = slice(characters, token)
          JSON::Any.new(selected.join)
        elsif position = token.to_i?
          position += characters.size if position < 0
          char = characters[position]?
          char ? traverse(JSON::Any.new(char.to_s), tokens, index + 1) : nil
        end
      end
    end

    private def slice(values : Array(T), token : String) : Array(T) forall T
      parts = token.split(':', remove_empty: false)
      start = parts[0]?.presence.try(&.to_i?) || 0
      stop = parts[1]?.presence.try(&.to_i?) || values.size
      step = parts[2]?.presence.try(&.to_i?) || 1
      raise UsageError.new("Output template slice step cannot be zero") if step == 0
      start += values.size if start < 0
      stop += values.size if stop < 0
      result = [] of T
      cursor = start
      while step > 0 ? cursor < stop : cursor > stop
        result << values[cursor] if 0 <= cursor < values.size
        cursor += step
      end
      result
    end

    private def format_value(value : JSON::Any, flags : String, type : Char, field : String) : String?
      case type
      when 's'
        printf_string(flags, scalar_string(value))
      when 'd', 'i', 'u', 'o', 'x', 'X'
        number = numeric(value)
        return unless number
        printf_number(flags, type, number.to_i64)
      when 'f', 'F', 'e', 'E', 'g', 'G'
        number = numeric(value)
        return unless number
        printf_number(flags, type, number)
      when 'c'
        scalar_string(value).chars.first?.try(&.to_s) || @na_placeholder
      when 'r'
        value.raw.inspect
      when 'j'
        flags.includes?('#') ? value.to_pretty_json : value.to_json
      when 'q'
        shell_quote(scalar_string(value))
      when 'l'
        items = value.as_a?.try(&.map { |item| scalar_string(item) }) || [scalar_string(value)]
        printf_string(flags.gsub("#", ""), items.join(flags.includes?('#') ? '\n' : ", "))
      when 'D'
        number = numeric(value)
        return unless number
        decimal_suffix(number, flags.includes?('#') ? 1024.0 : 1000.0, flags)
      when 'h'
        escape_html(scalar_string(value))
      when 'B'
        format_bytes(flags, scalar_string(value))
      when 'U'
        normalize_unicode(scalar_string(value), flags)
      when 'S'
        sanitize_value(field, scalar_string(value), restricted: flags.includes?('#'))
      else
        printf_string(flags, scalar_string(value))
      end
    end

    private def escape_html(value : String) : String
      value
        .gsub('&', "&amp;")
        .gsub('<', "&lt;")
        .gsub('>', "&gt;")
        .gsub('"', "&quot;")
        .gsub("'", "&#39;")
    end

    private def format_bytes(flags : String, value : String) : String
      bytes = value.to_slice
      width = extract_printf_width(flags)
      if width > 0
        pad_byte = flags.includes?('0') ? 0_u8 : 32_u8
        if bytes.size < width
          bytes = Bytes.new(width - bytes.size, pad_byte) + bytes
        elsif bytes.size > width
          bytes = bytes[0, width]
        end
      end
      String.new(bytes)
    end

    private def extract_printf_width(flags : String) : Int32
      match = flags.gsub("#", "").match(/\A0*(\d+)/)
      match ? match[1].to_i32 : 0
    end

    private def normalize_unicode(value : String, flags : String) : String
      form = if flags.includes?('+')
               flags.includes?('#') ? Unicode::NormalizationForm::NFKD : Unicode::NormalizationForm::NFKC
             else
               flags.includes?('#') ? Unicode::NormalizationForm::NFD : Unicode::NormalizationForm::NFC
             end
      value.unicode_normalize(form)
    end

    private def sanitize_value(key : String, value : String, restricted : Bool = false) : String
      return restricted_filename(value) if restricted || @restrict_filenames
      if @windows_filenames != false || {{ flag?(:win32) }}
        replacements = {
          '"'  => '＂',
          '*'  => '＊',
          ':'  => '：',
          '<'  => '＜',
          '>'  => '＞',
          '?'  => '？',
          '|'  => '｜',
          '/'  => '⧸',
          '\\' => '⧹',
        }
        sanitized = String.build do |output|
          value.each_char do |char|
            next if char.ord < 32 || char.ord == 127
            output << (replacements[char]? || char)
          end
        end.rstrip(" .")
        return sanitized.empty? ? "_" : sanitized
      end
      value.gsub('/', '⧸').delete('\0')
    end

    private def shell_quote(value : String) : String
      {% if flag?(:win32) %}
        return value if value.matches?(/\A[\w#$*\-+.\/:?@\\]+\z/)
        escaped = value.gsub(/(\\*)"/) { |match| "#{match[1..]}#{match[1..]}\\\"" }
        escaped = escaped.gsub(/(\\+)\z/) { |match| "#{match}#{match}" }
        "\"#{escaped.gsub("%", "%%cd:~,%")}\""
      {% else %}
        return "''" if value.empty?
        return value if value.matches?(/\A[\w@%+=:,\.\/-]+\z/)
        "'#{value.gsub("'", %q('"'"'))}'"
      {% end %}
    end

    private def printf_string(flags : String, value : String) : String
      format = flags.empty? ? "%s" : "%#{flags.gsub("#", "")}s"
      format % value
    rescue ArgumentError
      value
    end

    private def printf_number(flags : String, type : Char, value) : String
      format = "%#{flags.gsub(/\s+/, " ")}#{type}"
      format % value
    rescue ArgumentError
      value.to_s
    end

    private def decimal_suffix(number : Float64, base : Float64, flags : String) : String
      units = ["", "k", "M", "G", "T", "P"]
      value = number
      unit = 0
      while value.abs >= base && unit < units.size - 1
        value /= base
        unit += 1
      end
      clean_flags = flags.delete('#')
      return "#{value.to_i64}#{units[unit]}#{base == 1024 ? "i" : ""}" if clean_flags.empty?
      ("%#{clean_flags}f" % value) + units[unit] + (base == 1024 ? "i" : "")
    end

    private def numeric(value : JSON::Any) : Float64?
      value.as_f? || value.as_i64?.try(&.to_f64) || value.as_s?.try(&.to_f64?)
    end

    private def numeric_literal(value : String) : Float64?
      value.matches?(/\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/) ? value.to_f64 : nil
    end

    private def scalar_string(value : JSON::Any) : String
      case raw = value.raw
      when String then raw
      when Nil    then ""
      when Bool   then raw.to_s
      when Int64  then raw.to_s
      when Float64
        raw == raw.to_i64 ? raw.to_i64.to_s : raw.to_s
      else
        value.to_json
      end
    end

    private def missing?(value) : Bool
      !value.is_a?(JSON::Any) || value.raw.nil?
    end

    private def base_field(key : String) : String
      split_unescaped(split_once(split_once(key, '|')[0], '&')[0], ',').first
        .split(/[+*>]/, 2).first.lchop('-')
    end

    private def compatibility_width(
      field : String,
      values : Hash(String, JSON::Any),
    ) : Int32?
      case field
      when "autonumber"
        @autonumber_size
      when "playlist_index"
        digit_count(
          values["__last_playlist_index"]?.try(&.as_i64?) ||
          values["playlist_count"]?.try(&.as_i64?) || 0_i64
        )
      when "playlist_autonumber"
        digit_count(
          values["n_entries"]?.try(&.as_i64?) ||
          values["playlist_count"]?.try(&.as_i64?) || 0_i64
        )
      end
    end

    private def digit_count(value : Int64) : Int32
      Math.max(1, value.abs.to_s.size)
    end

    private def split_once(value : String, delimiter : Char) : Tuple(String, String?)
      escaped = false
      value.each_char_with_index do |char, index|
        if escaped
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif char == delimiter
          return {value[0...index], value[(index + 1)..]}
        end
      end
      {value, nil}
    end

    private def split_unescaped(value : String, delimiter : Char) : Array(String)
      result = [] of String
      start = 0
      escaped = false
      value.each_char_with_index do |char, index|
        if escaped
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif char == delimiter
          result << value[start...index]
          start = index + 1
        end
      end
      result << value[start..]
      result
    end

    private def unescape(value : String) : String
      value.gsub(/\\([,|&>\\])/, "\\1")
    end

    private def restricted_filename(value : String) : String
      normalized = value.unicode_normalize(:nfkd)
      sanitized = String.build do |output|
        normalized.each_char do |char|
          if char.ascii_alphanumeric? || char.in?('.', '_', '-')
            output << char
          elsif char.ascii_whitespace? || char.ord < 128
            output << '_'
          end
        end
      end
      sanitized = sanitized.gsub(/_+/, "_").strip("_.")
      sanitized.empty? ? "_" : sanitized
    end

    private def format_duration(value : Float64) : String
      total = value.round.to_i64
      hours = total // 3600
      minutes = (total % 3600) // 60
      seconds = total % 60
      "%02d:%02d:%02d" % {hours, minutes, seconds}
    end

    private def trim_filename(filename : String) : String
      return filename if @trim_file_name <= 0 || filename == "-"
      path = Path.new(filename)
      basename = path.basename
      extension = Path.new(basename).extension
      stem = extension.empty? ? basename : basename.rchop(extension)
      return filename if stem.size <= @trim_file_name
      trimmed = "#{stem[0, @trim_file_name]}#{extension}"
      parent = path.parent
      parent == Path["."] ? trimmed : parent.join(trimmed).to_s
    end
  end
end
