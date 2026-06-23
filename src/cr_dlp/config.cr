module CrDlp
  module Config
    extend self

    CONFIG_FILENAMES = %w[yt-dlp.conf]

    private record ExpansionChunk,
      from_config_location : Bool,
      arguments : Array(String)

    def tokenize(source : String) : Array(String)
      arguments = [] of String
      token = String::Builder.new
      quote = nil.as(Char?)
      escaped = false

      source.each_char do |char|
        if escaped
          token << char
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif quote
          if char == quote
            quote = nil
          else
            token << char
          end
        elsif char == '"' || char == '\''
          quote = char
        elsif char.whitespace?
          unless token.empty?
            arguments << token.to_s
            token = String::Builder.new
          end
        elsif char == '#'
          break
        else
          token << char
        end
      end
      raise UsageError.new("Unterminated quote in configuration") if quote
      arguments << token.to_s unless token.empty?
      arguments
    end

    def expand(arguments : Array(String), input : IO = STDIN) : Array(String)
      expand_sequence(arguments, input, Set(String).new)
    end

    def read(path : String, input : IO = STDIN) : Array(String)
      return read_stdin(input) if path == "-"

      resolved = resolve_path(path)
      arguments = [] of String
      File.each_line(resolved) { |line| arguments.concat(tokenize(line)) }
      arguments
    rescue error : File::Error
      raise UsageError.new("Unable to read configuration #{path}: #{error.message}", cause: error)
    end

    private def expand_sequence(
      arguments : Array(String),
      input : IO,
      seen : Set(String),
    ) : Array(String)
      chunks = [] of ExpansionChunk
      index = 0
      while index < arguments.size
        argument = arguments[index]
        if argument == "--"
          chunks << ExpansionChunk.new(false, arguments[index..])
          break
        elsif config_location_flag?(argument)
          path = arguments[index + 1]? || raise UsageError.new("#{argument} requires a path")
          chunks << ExpansionChunk.new(true, expand_config_location(path, input, seen))
          index += 1
        elsif value = inline_config_location(argument)
          chunks << ExpansionChunk.new(true, expand_config_location(value, input, seen))
        elsif argument == "--no-config-locations"
          chunks.reject!(&.from_config_location)
        else
          chunks << ExpansionChunk.new(false, [argument])
        end
        index += 1
      end
      chunks.flat_map(&.arguments)
    end

    private def config_location_flag?(argument : String) : Bool
      argument == "--config-locations" || argument == "--config-location"
    end

    private def inline_config_location(argument : String) : String?
      %w[--config-locations= --config-location=].each do |prefix|
        return argument[prefix.size..] if argument.starts_with?(prefix)
      end
    end

    private def expand_config_location(
      path : String,
      input : IO,
      seen : Set(String),
    ) : Array(String)
      return expand_sequence(read(path, input), input, seen) if path == "-"

      resolved = File.expand_path(resolve_path(path))
      raise UsageError.new("Recursive configuration reference: #{path}") if seen.includes?(resolved)

      seen.add(resolved)
      begin
        expand_sequence(read(resolved, input), input, seen)
      ensure
        seen.delete(resolved)
      end
    end

    private def read_stdin(input : IO) : Array(String)
      arguments = [] of String
      input.each_line { |line| arguments.concat(tokenize(line)) }
      arguments
    end

    private def resolve_path(path : String) : String
      return path unless File.directory?(path)
      CONFIG_FILENAMES.each do |filename|
        candidate = File.join(path, filename)
        return candidate if File.file?(candidate)
      end
      File.join(path, CONFIG_FILENAMES.first)
    end
  end
end
