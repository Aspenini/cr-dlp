module CrDlp
  module CLI
    extend self

    def run(arguments : Array(String)) : Int32
      if idx = arguments.index("--__jsinterp-eval")
        return run_jsinterp_eval(arguments[(idx + 1)..]? || [] of String)
      end
      if arguments.includes?("--__cookie-header-for")
        return run_cookie_header_for(arguments)
      end

      parser = ArgumentParser.new
      expanded = Config.expand(arguments)
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
      if options.enabled?("list_extractor_descriptions")
        print_extractor_descriptions
        return 0
      end
      if options.enabled?("list_impersonate_targets")
        print_impersonate_targets
        return 0
      end
      if update_target = requested_update(options)
        Updater.new.run(update_target)
        return 0
      end

      if options.bool?("rm_cachedir") == true
        Client.new(options).remove_cache_dir
        return 0 if options.urls.empty? && options.string?("load_info_filename").nil?
      end

      append_batch_urls(options)
      unless options.bool?("no_warnings") == true || options.bool?("quiet") == true
        options.warnings.each { |warning| STDERR.puts("WARNING: #{warning}") }
      end
      if options.urls.empty? && options.string?("load_info_filename").nil?
        raise UsageError.new("You must provide at least one URL")
      end
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

    private def print_extractors
      Client.new.extractor_registry.keys.each do |key|
        STDOUT.puts(key) unless key == "Fixture"
      end
    end

    private def print_extractor_descriptions
      Client.new.extractor_registry.registrations.each do |entry|
        next if entry.key == "Fixture"
        STDOUT.puts("#{entry.key}: #{entry.name}")
      end
    end

    private def print_impersonate_targets
      available = ImpersonateTargets.available
      STDOUT.puts("[info] Available impersonate targets")
      if available.empty?
        STDOUT.puts("Client\tOS\tSource")
        STDOUT.puts("-\t-\tcurl-impersonate (unavailable)")
        return
      end
      STDOUT.puts("Client\tOS\tSource")
      available.each do |entry|
        client = [entry.target.client, entry.target.version].compact.join("-")
        os = [entry.target.os, entry.target.os_version].compact.join("-")
        STDOUT.puts("#{client}\t#{os}\t#{entry.source}")
      end
    end

    private def requested_update(options : ParsedOptions) : String?
      value = options["update_self"]
      return nil if value.nil? || value.raw.nil? || value.as_bool? == false
      value.as_s? || "stable"
    end

    private def append_batch_urls(options : ParsedOptions)
      path = options.string?("batchfile")
      return unless path

      lines = if path == "-"
                STDIN.each_line.to_a
              else
                File.read_lines(path)
              end
      lines.each do |line|
        url = line.strip
        next if url.empty? || url.starts_with?("#") || url.starts_with?(";")
        options.urls << url
      end
    rescue error : File::Error
      raise UsageError.new("Unable to read batch file: #{error.message}", cause: error)
    end

    private def run_cookie_header_for(arguments : Array(String)) : Int32
      filtered = arguments.reject { |argument| argument == "--__cookie-header-for" }
      options = ArgumentParser.new.parse(filtered)
      url = options.urls.first? || raise UsageError.new("--__cookie-header-for requires URL")
      header = Client.new(options).cookie_jar.try(&.header_for(url))
      STDOUT.puts(header || "")
      0
    rescue error : Error
      STDERR.puts("ERROR: #{error.message}")
      1
    end

    private def run_jsinterp_eval(arguments : Array(String)) : Int32
      args = arguments.reject { |a| a.starts_with?("--") }
      raise UsageError.new("--__jsinterp-eval requires CODE FUNC [args...]") if args.size < 2

      code_arg = args[0]
      func = args[1]
      func_args = args[2..]? || [] of String

      code = if code_arg.starts_with?("@")
               File.read(code_arg[1..])
             else
               code_arg
             end

      jsi = JSInterpreter.new(code)
      parsed_args = func_args.map { |arg| parse_jsinterp_arg(arg) }
      result = jsi.extract_function(func).call(parsed_args)
      STDOUT.puts(JSInterpHelpers.js_value_to_json(result).to_json)
      0
    rescue error : Error
      STDERR.puts("ERROR: #{error.message}")
      1
    end

    private def parse_jsinterp_arg(arg : String) : JSValue
      case arg
      when "undefined"     then JS_UNDEFINED
      when "null"          then nil
      when "NaN"           then Float64::NAN
      when "true"          then true
      when "false"         then false
      when "", "__empty__" then ""
      else
        if arg.starts_with?("[") || arg.starts_with?("{")
          json_to_js_value(JSON.parse(arg))
        elsif arg.includes?(".")
          arg.to_f64
        elsif arg =~ /^-?\d+$/
          arg.to_i32
        else
          arg
        end
      end
    end

    private def json_to_js_value(value : JSON::Any) : JSValue
      JSInterpHelpers.json_any_to_js_value(value)
    end
  end
end
