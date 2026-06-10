module CrDlp
  module CLI
    extend self

    def run(arguments : Array(String)) : Int32
      parser = ArgumentParser.new
      expanded = expand_config(arguments)
      options = parser.parse(expanded)

      if options.enabled?("help") || options.enabled?("print_help")
        STDOUT.print(parser.schema.help)
        return 0
      end
      if options.enabled?("_version")
        STDOUT.puts("cr-dlp #{VERSION} (compatible baseline #{BASELINE_COMMIT})")
        return 0
      end
      if options.enabled?("list_extractors")
        print_extractors
        return 0
      end

      options.warnings.each { |warning| STDERR.puts("WARNING: #{warning}") }
      raise UsageError.new("You must provide at least one URL") if options.urls.empty?
      Client.new(options).download(options.urls)
    rescue error : UsageError
      STDERR.puts("Usage: cr-dlp [OPTIONS] URL [URL...]")
      STDERR.puts("cr-dlp: error: #{error.message}")
      2
    rescue error : Error
      STDERR.puts("ERROR: #{error.message}")
      1
    rescue error : IO::Error
      return 0 if error.message.to_s.downcase.includes?("pipe")
      STDERR.puts("ERROR: I/O failure: #{error.message}")
      1
    rescue error
      STDERR.puts("ERROR: unexpected failure: #{error.message}")
      1
    end

    private def expand_config(arguments : Array(String)) : Array(String)
      expanded = [] of String
      index = 0
      while index < arguments.size
        argument = arguments[index]
        if argument == "--config-location"
          path = arguments[index + 1]? || raise UsageError.new("--config-location requires a path")
          expanded.concat(Config.read(path))
          index += 1
        elsif argument.starts_with?("--config-location=")
          expanded.concat(Config.read(argument.partition('=')[2]))
        else
          expanded << argument
        end
        index += 1
      end
      expanded
    end

    private def print_extractors
      Client.new.extractor_registry.keys.each do |key|
        STDOUT.puts(key) unless key == "Fixture"
      end
    end
  end
end
