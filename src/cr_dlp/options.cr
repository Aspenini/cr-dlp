module CrDlp
  class OptionDefinition
    include JSON::Serializable

    getter flags : Array(String)
    getter dest : String?
    getter action : String
    getter value_type : String?
    getter default : JSON::Any?
    getter const_value : JSON::Any?
    getter metavar : String?
    getter help : String?
    getter group : String
    getter callback : String?
    getter takes_value : Bool

    @[JSON::Field(key: "type")]
    @value_type : String?

    @[JSON::Field(key: "const")]
    @const_value : JSON::Any?
  end

  class OptionSchema
    BASELINE_JSON = {{ read_file("#{__DIR__}/../../baseline/crystal/options.json") }}

    getter definitions : Array(OptionDefinition)

    @by_flag : Hash(String, OptionDefinition)

    def initialize
      @definitions = Array(OptionDefinition).from_json(BASELINE_JSON)
      @by_flag = Hash(String, OptionDefinition).new
      @definitions.each do |definition|
        definition.flags.each { |flag| @by_flag[flag] = definition }
      end
    end

    def find(flag : String) : OptionDefinition?
      @by_flag[flag]?
    end

    def option_count : Int32
      @definitions.size
    end

    def help(prog = "cr-dlp") : String
      String.build do |io|
        io << "Usage: " << prog << " [OPTIONS] URL [URL...]\n\n"
        current_group = ""
        @definitions.each do |definition|
          next if definition.flags.empty? || definition.help == "SUPPRESSHELP"
          if definition.group != current_group
            current_group = definition.group
            io << current_group << ":\n"
          end
          label = definition.flags.join(", ")
          label += " #{definition.metavar || "VALUE"}" if definition.takes_value
          io << "  " << label
          if help = definition.help
            padding = Math.max(2, 34 - label.size)
            io << " " * padding << help.gsub('\n', ' ')
          end
          io << '\n'
        end
      end
    end
  end

  class ParsedOptions
    getter values : Hash(String, JSON::Any)
    getter urls : Array(String)
    getter warnings : Array(String)

    def initialize(
      @values = Hash(String, JSON::Any).new,
      @urls = [] of String,
      @warnings = [] of String,
    )
    end

    def [](key : String) : JSON::Any?
      @values[key]?
    end

    def string?(key : String) : String?
      self[key].try(&.as_s?)
    end

    def bool?(key : String) : Bool?
      self[key].try(&.as_bool?)
    end

    def int?(key : String) : Int64?
      self[key].try(&.as_i64?)
    end

    def float?(key : String) : Float64?
      value = self[key]
      return unless value
      value.as_f? || value.as_i64?.try(&.to_f64)
    end

    def hash?(key : String) : Hash(String, JSON::Any)?
      self[key].try(&.as_h?)
    end

    def array?(key : String) : Array(JSON::Any)?
      self[key].try(&.as_a?)
    end

    def enabled?(key : String) : Bool
      bool?(key) == true
    end
  end

  class ArgumentParser
    POSTPROCESS_STAGES = %w[
      pre_process after_filter video before_dl post_process after_move
      after_video playlist
    ]
    SPONSORBLOCK_CATEGORIES = %w[
      sponsor intro outro selfpromo preview filler interaction music_offtopic
      hook poi_highlight chapter
    ]
    SPONSORBLOCK_NON_SKIPPABLE = %w[poi_highlight chapter]

    getter schema : OptionSchema

    def initialize(@schema = OptionSchema.new)
    end

    def parse(arguments : Array(String)) : ParsedOptions
      result = ParsedOptions.new(default_values)
      index = 0
      while index < arguments.size
        argument = arguments[index]
        if argument == "--"
          result.urls.concat(arguments[(index + 1)..])
          break
        elsif argument.starts_with?("--")
          flag, inline_value = split_long_option(argument)
          definition = @schema.find(flag) || raise UsageError.new("no such option: #{flag}")
          index = apply(definition, inline_value, arguments, index, result)
        elsif argument.starts_with?("-") && argument != "-"
          index = parse_short(argument, arguments, index, result)
        else
          result.urls << argument
        end
        index += 1
      end
      result
    end

    private def default_values : Hash(String, JSON::Any)
      values = Hash(String, JSON::Any).new
      @schema.definitions.each do |definition|
        if dest = definition.dest
          if default = definition.default
            values[dest] = default
          end
        end
      end
      values
    end

    private def split_long_option(argument : String) : Tuple(String, String?)
      if separator = argument.index('=')
        {argument[0, separator], argument[(separator + 1)..]}
      else
        {argument, nil}
      end
    end

    private def parse_short(
      argument : String,
      arguments : Array(String),
      index : Int32,
      result : ParsedOptions,
    ) : Int32
      if definition = @schema.find(argument)
        return apply(definition, nil, arguments, index, result)
      end

      cursor = 1
      while cursor < argument.size
        flag = "-#{argument[cursor]}"
        definition = @schema.find(flag) || raise UsageError.new("no such option: #{flag}")
        inline_value = definition.takes_value && cursor + 1 < argument.size ? argument[(cursor + 1)..] : nil
        index = apply(definition, inline_value, arguments, index, result)
        return index if definition.takes_value
        cursor += 1
      end
      index
    end

    private def apply(
      definition : OptionDefinition,
      inline_value : String?,
      arguments : Array(String),
      index : Int32,
      result : ParsedOptions,
    ) : Int32
      if definition.action == "version"
        result.values["_version"] = JSON::Any.new(true)
        return index
      end

      if definition.callback == "_deprecated_option_callback"
        result.warnings << "Deprecated option ignored: #{definition.flags.last}"
        return definition.takes_value ? consume_value(inline_value, arguments, index)[1] : index
      end

      dest = definition.dest
      return index unless dest

      case definition.action
      when "store_true"
        result.values[dest] = JSON::Any.new(true)
      when "store_false"
        result.values[dest] = JSON::Any.new(false)
      when "store_const"
        result.values[dest] = definition.const_value || JSON::Any.new(nil)
      when "append"
        value, index = consume_value(inline_value, arguments, index)
        validate_chapter_expression(value) if dest == "remove_chapters"
        append_value(result.values, dest, convert(value, definition.value_type))
      when "callback"
        if definition.takes_value
          value, index = consume_value(inline_value, arguments, index)
          if definition.flags.includes?("--replace-in-metadata")
            search, index = consume_value(nil, arguments, index)
            replacement, index = consume_value(nil, arguments, index)
            apply_metadata_replacement(result.values, value, search, replacement)
          elsif definition.flags.includes?("--print-to-file")
            path, index = consume_value(nil, arguments, index)
            apply_print_to_file(result.values, value, path)
          else
            apply_callback(result.values, definition, value)
          end
        elsif definition.flags.includes?("--write-thumbnail")
          result.values[dest] = JSON::Any.new(true) unless result.values[dest]?.try(&.as_s?) == "all"
        end
      else
        value, index = consume_value(inline_value, arguments, index)
        result.values[dest] = convert(value, definition.value_type)
      end
      index
    end

    private def consume_value(
      inline_value : String?,
      arguments : Array(String),
      index : Int32,
    ) : Tuple(String, Int32)
      return {inline_value, index} if inline_value
      next_index = index + 1
      value = arguments[next_index]? || raise UsageError.new("option requires an argument")
      {value, next_index}
    end

    private def convert(value : String, type : String?) : JSON::Any
      case type
      when "int"
        JSON::Any.new(value.to_i64)
      when "float"
        JSON::Any.new(value.to_f64)
      else
        JSON::Any.new(value)
      end
    rescue error : ArgumentError
      raise UsageError.new("invalid #{type || "string"} value: #{value}", cause: error)
    end

    private def append_value(values : Hash(String, JSON::Any), dest : String, value : JSON::Any)
      entries = values[dest]?.try(&.as_a?) || [] of JSON::Any
      entries << value
      values[dest] = JSON::Any.new(entries)
    end

    private def validate_chapter_expression(value : String)
      unless value.starts_with?('*')
        begin
          Regex.new(value)
          return
        rescue error : ArgumentError
          raise UsageError.new("invalid --remove-chapters regex #{value.inspect}: #{error.message}")
        end
      end

      value.lchop('*').split(',').each do |entry|
        start_time, separator, end_time = entry.strip.partition('-')
        if separator.empty? || !valid_chapter_timestamp?(start_time, allow_inf: false) ||
           !valid_chapter_timestamp?(end_time, allow_inf: true)
          raise UsageError.new(
            "invalid --remove-chapters time range #{value.inspect}; expected *START-END",
          )
        end
      end
    end

    private def valid_chapter_timestamp?(value : String, *, allow_inf : Bool) : Bool
      text = value.strip
      return true if text.empty? || (allow_inf && text == "inf")
      text.split(':').all? { |part| !part.empty? && !part.to_f64?.nil? }
    end

    private def apply_callback(
      values : Hash(String, JSON::Any),
      definition : OptionDefinition,
      value : String,
    )
      dest = definition.dest.not_nil!
      case definition.callback
      when "_list_from_options_callback"
        entries = values[dest]?.try(&.as_a?) || [] of JSON::Any
        additions = value.split(',').compact_map do |entry|
          item = entry.strip
          JSON::Any.new(item) unless item.empty?
        end
        entries = additions + entries if dest == "format_sort"
        entries.concat(additions) unless dest == "format_sort"
        values[dest] = JSON::Any.new(entries)
      when "_set_from_options_callback"
        if dest.in?("sponsorblock_mark", "sponsorblock_remove")
          apply_sponsorblock_categories(values, dest, value)
          return
        end
        entries = values[dest]?.try(&.as_a?) || [] of JSON::Any
        value.split(',').each do |entry|
          item = JSON::Any.new(entry)
          entries << item unless entries.includes?(item)
        end
        values[dest] = JSON::Any.new(entries)
      when "_dict_from_options_callback"
        if dest == "parse_metadata"
          apply_metadata_interpret(values, value)
          return
        end
        key, item = dictionary_entry(dest, value)
        dictionary = values[dest]?.try(&.as_h?) || Hash(String, JSON::Any).new
        if dest.in?("forceprint", "exec_cmd")
          templates = dictionary[key]?.try(&.as_a?) || [] of JSON::Any
          templates << JSON::Any.new(item)
          dictionary[key] = JSON::Any.new(templates)
        else
          dictionary[key] = JSON::Any.new(item)
        end
        values[dest] = JSON::Any.new(dictionary)
      else
        values[dest] = JSON::Any.new(value)
      end
    end

    private def apply_sponsorblock_categories(
      values : Hash(String, JSON::Any),
      dest : String,
      value : String,
    )
      allowed = if dest == "sponsorblock_remove"
                  SPONSORBLOCK_CATEGORIES.reject { |category| SPONSORBLOCK_NON_SKIPPABLE.includes?(category) }
                else
                  SPONSORBLOCK_CATEGORIES
                end
      selected = values[dest]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      value.split(',').each do |raw_token|
        token = raw_token.strip.downcase
        next if token.empty?
        remove = token.starts_with?('-')
        token = token.lchop('-')
        expansion = case token
                    when "all"
                      allowed
                    when "default"
                      dest == "sponsorblock_remove" ? allowed.reject(&.==("filler")) : allowed
                    else
                      unless allowed.includes?(token)
                        raise UsageError.new("invalid SponsorBlock category #{token.inspect}")
                      end
                      [token]
                    end
        if remove
          selected.reject! { |category| expansion.includes?(category) }
        else
          expansion.each { |category| selected << category unless selected.includes?(category) }
        end
      end
      values[dest] = JSON::Any.new(selected.map { |category| JSON::Any.new(category) })
    end

    private def apply_metadata_interpret(values : Hash(String, JSON::Any), value : String)
      stage, expression = dictionary_entry("parse_metadata", value)
      separator = unescaped_colon(expression)
      unless separator
        raise UsageError.new(
          "invalid --parse-metadata value #{value.inspect}; expected [WHEN:]FROM:TO",
        )
      end
      input = expression[0...separator].gsub("\\:", ":")
      output = expression[(separator + 1)..]
      raise UsageError.new("metadata output pattern cannot be empty") if output.empty?
      append_metadata_action(values, stage, {
        "type"   => JSON::Any.new("interpret"),
        "input"  => JSON::Any.new(input),
        "output" => JSON::Any.new(output),
      })
    end

    private def apply_metadata_replacement(
      values : Hash(String, JSON::Any),
      field_spec : String,
      search : String,
      replacement : String,
    )
      stage, fields = dictionary_entry("parse_metadata", field_spec)
      begin
        Regex.new(search)
      rescue error : ArgumentError
        raise UsageError.new("invalid metadata replacement regex #{search.inspect}: #{error.message}")
      end
      fields.split(',').each do |field|
        name = field.strip
        next if name.empty?
        append_metadata_action(values, stage, {
          "type"        => JSON::Any.new("replace"),
          "field"       => JSON::Any.new(name),
          "search"      => JSON::Any.new(search),
          "replacement" => JSON::Any.new(replacement),
        })
      end
    end

    private def apply_print_to_file(
      values : Hash(String, JSON::Any),
      template_spec : String,
      path : String,
    )
      stage, template = dictionary_entry("print_to_file", template_spec)
      dictionary = values["print_to_file"]?.try(&.as_h?) || Hash(String, JSON::Any).new
      entries = dictionary[stage]?.try(&.as_a?) || [] of JSON::Any
      entries << JSON::Any.new({
        "template" => JSON::Any.new(template),
        "path"     => JSON::Any.new(path),
      })
      dictionary[stage] = JSON::Any.new(entries)
      values["print_to_file"] = JSON::Any.new(dictionary)
    end

    private def append_metadata_action(
      values : Hash(String, JSON::Any),
      stage : String,
      action : Hash(String, JSON::Any),
    )
      dictionary = values["parse_metadata"]?.try(&.as_h?) || Hash(String, JSON::Any).new
      actions = dictionary[stage]?.try(&.as_a?) || [] of JSON::Any
      actions << JSON::Any.new(action)
      dictionary[stage] = JSON::Any.new(actions)
      values["parse_metadata"] = JSON::Any.new(dictionary)
    end

    private def dictionary_entry(dest : String, value : String) : Tuple(String, String)
      key, separator, item = value.partition(':')
      if separator.empty? || windows_path_prefix?(key, item)
        return {default_dictionary_key(dest), value}
      end
      if dest.in?("forceprint", "print_to_file", "exec_cmd", "parse_metadata")
        return POSTPROCESS_STAGES.includes?(key) ? {key, item} : {default_dictionary_key(dest), value}
      end
      {key, item}
    end

    private def unescaped_colon(value : String) : Int32?
      escaped = false
      value.each_char_with_index do |char, index|
        if char == ':' && !escaped
          return index
        end
        escaped = char == '\\' && !escaped
        escaped = false unless char == '\\'
      end
      nil
    end

    private def windows_path_prefix?(key : String, item : String) : Bool
      key.size == 1 && key[0].ascii_letter? && (item.starts_with?('\\') || item.starts_with?('/'))
    end

    private def default_dictionary_key(dest : String) : String
      case dest
      when "outtmpl"                     then "default"
      when "paths"                       then "home"
      when "forceprint", "print_to_file" then "video"
      when "exec_cmd"                    then "after_move"
      when "parse_metadata"              then "pre_process"
      else                                    "default"
      end
    end
  end
end
