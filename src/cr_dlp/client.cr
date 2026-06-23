require "base64"
require "file_utils"

module CrDlp
  class RateLimitedIO < IO
    def initialize(
      @destination : IO,
      @client : Client,
      @start_offset = 0_i64,
      @started_at = Time.utc,
    )
      @written = @start_offset
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("RateLimitedIO is write-only")
    end

    def write(slice : Bytes) : Nil
      @destination.write(slice)
      @written += slice.size
      @client.throttle_download(@written, @started_at)
    end

    def flush
      @destination.flush
    end
  end

  record NetrcEntry,
    machine : String,
    login : String?,
    password : String?

  class Client
    getter options : ParsedOptions
    getter extractor_registry : ExtractorRegistry
    getter downloader_registry : DownloaderRegistry
    getter postprocessor_registry : PostProcessorRegistry
    getter request_director : Networking::RequestDirector
    getter process_runner : ProcessRunner
    getter xattr_writer : XAttrWriter
    getter download_archive : DownloadArchive?
    getter cookie_jar : CookieJar?

    @progress_hooks = [] of ProgressHook
    @postprocessor_hooks = [] of ProgressHook
    @extractor_instances = Hash(String, Extractor).new
    @postprocessors = [] of PostProcessor
    @hls_keys = Hash(String, Bytes).new
    @num_downloads = 0_i64
    @download_limit_base = 0_i64
    @last_progress_output_at : Time? = nil
    @netrc_entries : Array(NetrcEntry)?

    def initialize(
      @options = ParsedOptions.new,
      @extractor_registry = ExtractorRegistry.new,
      @downloader_registry = DownloaderRegistry.new,
      @postprocessor_registry = PostProcessorRegistry.new,
      @request_director = Networking::RequestDirector.new,
      @process_runner = SystemProcessRunner.new,
      xattr_writer : XAttrWriter? = nil,
      @input : IO = STDIN,
      @output : IO = STDOUT,
      @error : IO = STDERR,
      @sleeper : Proc(Time::Span, Nil) = ->(span : Time::Span) { sleep span },
      auto_init = true,
    )
      @xattr_writer = xattr_writer || SystemXAttrWriter.new(@process_runner)
      @download_archive = @options.string?("download_archive").try { |path| DownloadArchive.new(path) }
      @cookie_jar = build_cookie_jar
      register_defaults if auto_init
    end

    def register_defaults
      if impersonate = ImpersonateTarget.parse_option(@options.string?("impersonate"))
        @request_director.add(Networking::CurlImpersonateHandler.new(
          impersonate: impersonate,
          timeout: (@options.float?("socket_timeout") || 20).seconds,
          cookie_jar: @cookie_jar,
          proxy: @options.string?("proxy"),
        ))
      end
      @request_director.add(Networking::CrystalHttpHandler.new(
        timeout: (@options.float?("socket_timeout") || 20).seconds,
        verify_tls: !skip_certificate_check?,
        default_headers: default_http_headers,
        cookie_jar: @cookie_jar,
        proxy: @options.string?("proxy"),
      ))
      @request_director.add(Networking::CrystalWebSocketHandler.new(
        timeout: (@options.float?("socket_timeout") || 20).seconds,
        verify_tls: !skip_certificate_check?,
        default_headers: default_http_headers,
        cookie_jar: @cookie_jar,
        proxy: @options.string?("proxy"),
        client_certificate: @options.string?("client_certificate"),
        client_certificate_key: @options.string?("client_certificate_key"),
      ))
      @extractor_registry.register("Fixture", "fixture") { |client| FixtureExtractor.new(client) }
      @extractor_registry.register("File", "file") { |client| FileExtractor.new(client) }
      @extractor_registry.register("ArchiveOrg", "archive.org") { |client| ArchiveOrgExtractor.new(client) }
      # Generic must remain the final fallback.
      @extractor_registry.register("Generic", "generic") { |client| GenericExtractor.new(client) }
      @downloader_registry.register(["fixture"]) { |client| FixtureDownloader.new(client) }
      @downloader_registry.register(["file"]) { |client| FileDownloader.new(client) }
      @downloader_registry.register(["http", "https"]) { |client| HttpDownloader.new(client) }
      @downloader_registry.register(["m3u8", "m3u8_native"]) { |client| HlsDownloader.new(client) }
      @downloader_registry.register(["http_dash_segments"]) { |client| DashDownloader.new(client) }
      @downloader_registry.register(["websocket_frag", "web_socket_fragment"]) do |client|
        WebSocketFragmentDownloader.new(client)
      end
      @postprocessor_registry.register("Metadata") { |client| MetadataPostProcessor.new(client) }
      @postprocessor_registry.register("MetadataParser") { |client| MetadataParserPostProcessor.new(client, [] of JSON::Any) }
      @postprocessor_registry.register("SponsorBlock") { |client| SponsorBlockPostProcessor.new(client) }
      @postprocessor_registry.register("ModifyChapters") { |client| ModifyChaptersPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegSplitChapters") { |client| FFmpegSplitChaptersPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegConcat") { |client| FFmpegConcatPostProcessor.new(client) }
      @postprocessor_registry.register("XAttrMetadata") { |client| XAttrMetadataPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegExtractAudio") { |client| FFmpegExtractAudioPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegVideoRemuxer") { |client| FFmpegVideoRemuxerPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegVideoConvertor") { |client| FFmpegVideoConvertorPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegMetadata") { |client| FFmpegMetadataPostProcessor.new(client) }
      @postprocessor_registry.register("Exec") { |client| ExecPostProcessor.new(client, [] of String) }
      @postprocessor_registry.register("MoveFiles") { |client| MoveFilesAfterDownloadPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegMerger") { |client| FFmpegMergerPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegSubtitlesConvertor") { |client| FFmpegSubtitlesConvertorPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegThumbnailsConvertor") { |client| FFmpegThumbnailsConvertorPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegEmbedSubtitle") { |client| FFmpegEmbedSubtitlePostProcessor.new(client) }
      @postprocessor_registry.register("EmbedThumbnail") { |client| EmbedThumbnailPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegFixupStretched") { |client| FFmpegFixupStretchedPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegFixupM4a") { |client| FFmpegFixupM4aPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegFixupM3u8") { |client| FFmpegFixupM3u8PostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegFixupTimestamp") { |client| FFmpegFixupTimestampPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegFixupDuration") { |client| FFmpegFixupDurationPostProcessor.new(client) }
      @postprocessor_registry.register("FFmpegFixupDuplicateMoov") { |client| FFmpegFixupDuplicateMoovPostProcessor.new(client) }
    end

    def add_progress_hook(&hook : Hash(String, JSON::Any) ->)
      @progress_hooks << hook
    end

    def add_postprocessor_hook(&hook : Hash(String, JSON::Any) ->)
      @postprocessor_hooks << hook
    end

    def add_post_processor(postprocessor : PostProcessor)
      @postprocessors << postprocessor
    end

    def publish_progress(event : Hash(String, JSON::Any))
      @progress_hooks.each(&.call(event))
      render_progress(event)
    end

    def warning(message : String)
      return if @options.bool?("no_warnings") == true || @options.bool?("quiet") == true
      @error.puts("WARNING: #{message}")
    end

    def info_log(message : String)
      return if @options.bool?("quiet") == true
      @error.puts(message)
    end

    private def skip_certificate_check? : Bool
      @options.bool?("no_check_certificate") == true ||
        @options.bool?("nocheckcertificate") == true
    end

    private def authorized_request(request : Networking::Request) : Networking::Request
      return request if request.headers.has_key?("Authorization")
      authorization = authorization_header(request.url)
      return request unless authorization

      headers = request.headers.dup
      headers["Authorization"] = authorization
      Networking::Request.new(
        request.url,
        method: request.method,
        headers: headers,
        body: request.body,
      )
    end

    private def authorization_header(url : String) : String?
      uri = URI.parse(url)
      if user = uri.user
        password = uri.password || ""
        return basic_authorization(URI.decode(user), URI.decode(password))
      end

      if user = @options.string?("username")
        return basic_authorization(user, @options.string?("password") || "")
      end

      return unless netrc_enabled?
      host = uri.hostname || return
      if entry = netrc_entry(host)
        login = entry.login
        return basic_authorization(login, entry.password || "") if login
      end
    rescue URI::Error
      nil
    end

    private def basic_authorization(username : String, password : String) : String
      "Basic #{Base64.strict_encode("#{username}:#{password}")}"
    end

    private def netrc_enabled? : Bool
      @options.bool?("usenetrc") == true ||
        !@options.string?("netrc_location").nil? ||
        !@options.string?("netrc_cmd").nil?
    end

    private def netrc_entry(host : String) : NetrcEntry?
      entries = netrc_entries
      entries.find { |entry| entry.machine == host } ||
        entries.find { |entry| entry.machine == "default" }
    end

    private def netrc_entries : Array(NetrcEntry)
      @netrc_entries ||= parse_netrc(netrc_source)
    end

    private def netrc_source : String
      if command = @options.string?("netrc_cmd")
        result = @process_runner.run_shell(command)
        unless result.success?
          detail = result.error.strip
          detail = "exit code #{result.exit_code}" if detail.empty?
          raise UsageError.new("--netrc-cmd failed: #{detail}")
        end
        return result.output
      end

      path = @options.string?("netrc_location") || default_netrc_path
      File.exists?(path) ? File.read(path) : ""
    rescue error : File::Error
      raise UsageError.new("Unable to read netrc: #{error.message}", cause: error)
    end

    private def default_netrc_path : String
      home = ENV["HOME"]? || ENV["USERPROFILE"]? || "."
      File.join(home, {{ flag?(:win32) ? "_netrc" : ".netrc" }})
    end

    private def parse_netrc(source : String) : Array(NetrcEntry)
      tokens = [] of String
      source.each_line do |line|
        stripped = line.partition('#')[0].strip
        next if stripped.empty?
        tokens.concat(stripped.split(/\s+/))
      end

      entries = [] of NetrcEntry
      machine = nil.as(String?)
      login = nil.as(String?)
      password = nil.as(String?)
      flush = -> {
        if current = machine
          entries << NetrcEntry.new(current, login, password)
        end
      }

      index = 0
      while index < tokens.size
        token = tokens[index]
        case token
        when "machine"
          flush.call
          machine = tokens[index + 1]?
          login = nil
          password = nil
          index += 1
        when "default"
          flush.call
          machine = "default"
          login = nil
          password = nil
        when "login", "user"
          login = tokens[index + 1]?
          index += 1
        when "password"
          password = tokens[index + 1]?
          index += 1
        when "account"
          index += 1
        end
        index += 1
      end
      flush.call
      entries
    end

    def send_request(request : Networking::Request) : Networking::Response
      sleep_for_request
      @request_director.send(authorized_request(request))
    end

    def download_request(
      request : Networking::Request,
      destination : IO,
      progress : Proc(Int64, Int64?, Nil)? = nil,
    ) : Networking::Response
      sleep_for_request
      @request_director.download(authorized_request(request), destination, progress)
    end

    def probe_request(request : Networking::Request, max_bytes = 1024) : Networking::Response
      sleep_for_request
      @request_director.probe(authorized_request(request), max_bytes)
    end

    def open_websocket(request : Networking::Request) : Networking::WebSocketResponse
      sleep_for_request
      @request_director.open_websocket(authorized_request(request))
    end

    def rate_limited_io(destination : IO, start_offset = 0_i64) : IO
      return destination unless rate_limit
      RateLimitedIO.new(destination, self, start_offset)
    end

    def copy_stream(input : IO, output : IO, start_offset = 0_i64) : Int64
      throttled = rate_limited_io(output, start_offset)
      total = start_offset
      buffer = Bytes.new(buffer_size)
      loop do
        count = input.read(buffer)
        break if count == 0
        throttled.write(buffer[0, count])
        total += count
      end
      throttled.flush
      total
    end

    def throttle_download(downloaded : Int64, started_at : Time)
      limit = rate_limit
      return unless limit && limit > 0
      expected = downloaded.to_f / limit
      elapsed = (Time.utc - started_at).total_seconds
      delay = expected - elapsed
      sleep_for(delay.seconds) if delay > 0
    end

    def buffer_size : Int32
      size = @options.string?("buffersize").try { |value| parse_byte_size(value, "--buffer-size") } || 1024_i64
      Math.max(1, Math.min(size, Int32::MAX)).to_i
    end

    def rate_limit : Int64?
      @rate_limit ||= @options.string?("ratelimit").try { |value| parse_byte_size(value, "--rate-limit") }
    end

    @rate_limit : Int64?

    def http_chunk_size : Int64?
      value = @options.string?("http_chunk_size") || return
      size = parse_byte_size(value, "--http-chunk-size")
      size > 0 ? size : nil
    end

    def retry_sleep(kind : String, attempt : Int32, fallback : Time::Span) : Time::Span
      expressions = @options.hash?("retry_sleep")
      return fallback unless expressions
      expression = expressions[kind]?.try(&.as_s?) ||
                   expressions["default"]?.try(&.as_s?)
      return fallback unless expression
      parse_retry_sleep(expression, attempt)
    end

    def fragment_retry_count : Int32
      retry_count_from_option("fragment_retries", 10)
    end

    def sleep_for(span : Time::Span)
      return unless span.total_seconds > 0
      @sleeper.call(span)
    end

    def hls_key(url : String, headers : Hash(String, String)) : Bytes
      @hls_keys[url] ||= send_request(Networking::Request.new(url, headers: headers)).body
    end

    def cache_directory : String?
      value = @options["cachedir"]
      return nil if value && value.as_bool? == false
      if path = value.try(&.as_s?)
        return File.expand_path(path)
      end
      default_cache_directory
    end

    def remove_cache_dir
      directory = cache_directory || return
      existed = Dir.exists?(directory)
      FileUtils.rm_rf(directory) if existed
      info_log("[cache] Removed #{directory}") if existed
    rescue error
      raise DownloadError.new("Unable to remove cache directory: #{error.message}", cause: error)
    end

    private def sleep_for_request
      interval = @options.float?("sleep_interval_requests") || 0.0
      sleep_for(interval.seconds)
    end

    private def default_cache_directory : String
      if root = ENV["XDG_CACHE_HOME"]?
        return File.join(root, "yt-dlp")
      end
      {% if flag?(:win32) %}
        if root = ENV["LOCALAPPDATA"]?
          return File.join(root, "yt-dlp", "Cache")
        end
      {% end %}
      home = ENV["HOME"]? || ENV["USERPROFILE"]? || "."
      File.join(home, ".cache", "yt-dlp")
    end

    private def sleep_for_subtitle
      interval = @options.float?("sleep_interval_subtitles") || 0.0
      sleep_for(interval.seconds)
    end

    private def sleep_for_media_download
      minimum = @options.float?("sleep_interval")
      return unless minimum
      maximum = @options.float?("max_sleep_interval") || minimum
      if maximum < minimum
        raise UsageError.new("--max-sleep-interval must be greater than or equal to --sleep-interval")
      end
      interval = maximum == minimum ? minimum : Random.rand(minimum..maximum)
      sleep_for(interval.seconds)
    end

    private def render_progress(event : Hash(String, JSON::Any))
      return if @options.bool?("noprogress") == true || @options.bool?("quiet") == true
      template = progress_template(event) || return
      return unless progress_delta_elapsed?(event)

      info = progress_info(event)
      rendered = output_template_renderer.render(template, info, Math.max(1_i64, @num_downloads), sanitize: false)
      if @options.bool?("progress_with_newline") == true || event["status"]?.try(&.as_s?) == "finished"
        @error.puts(rendered)
      else
        @error.print("\r#{rendered}")
        @error.flush
      end
    end

    private def progress_template(event : Hash(String, JSON::Any)) : String?
      templates = @options.hash?("progress_template")
      return unless templates && !templates.empty?
      status = event["status"]?.try(&.as_s?) || "download"
      templates[status]?.try(&.as_s?) ||
        templates["download"]?.try(&.as_s?) ||
        templates["default"]?.try(&.as_s?)
    end

    private def progress_delta_elapsed?(event : Hash(String, JSON::Any)) : Bool
      return true if event["status"]?.try(&.as_s?) == "finished"
      delta = @options.float?("progress_delta") || 0.0
      return true if delta <= 0
      now = Time.utc
      previous = @last_progress_output_at
      if previous && (now - previous).total_seconds < delta
        return false
      end
      @last_progress_output_at = now
      true
    end

    private def progress_info(event : Hash(String, JSON::Any)) : Info
      data = event["info_dict"]?.try(&.as_h?).try(&.dup) || Hash(String, JSON::Any).new
      progress = Hash(String, JSON::Any).new
      event.each do |key, value|
        next if key == "info_dict"
        progress[key] = value
      end
      progress["_default_template"] = JSON::Any.new(default_progress_text(progress))
      data["progress"] = JSON::Any.new(progress)
      Info.new(data)
    end

    private def default_progress_text(progress : Hash(String, JSON::Any)) : String
      status = progress["status"]?.try(&.as_s?) || "download"
      downloaded = progress["downloaded_bytes"]?.try(&.as_i64?) || 0_i64
      total = progress["total_bytes"]?.try(&.as_i64?)
      total_text = total ? "/#{total}" : ""
      "[#{status}] #{downloaded}#{total_text} bytes"
    end

    private def retry_count_from_option(key : String, fallback : Int32) : Int32
      value = @options[key]
      return fallback unless value
      if count = value.as_i64?
        return Math.max(0, count.to_i)
      end
      text = value.as_s?
      return fallback unless text
      return Int32::MAX if text == "infinite"
      Math.max(0, text.to_i? || fallback)
    end

    private def parse_retry_sleep(expression : String, attempt : Int32) : Time::Span
      text = expression.strip
      return text.to_f.seconds if text.to_f?

      name, separator, payload = text.partition('=')
      unless separator == "="
        raise UsageError.new("invalid --retry-sleep expression #{expression.inspect}")
      end
      values = payload.split(':').map { |part| part.empty? ? nil : part.to_f? }
      start = values[0]? || raise UsageError.new("invalid --retry-sleep start #{expression.inspect}")
      ceiling = values[1]?
      case name
      when "linear"
        step = values[2]? || 1.0
        seconds = start + step * attempt
        seconds = Math.min(seconds, ceiling) if ceiling
        seconds.seconds
      when "exp"
        factor = values[2]? || 2.0
        seconds = start * (factor ** attempt)
        seconds = Math.min(seconds, ceiling) if ceiling
        seconds.seconds
      else
        raise UsageError.new("invalid --retry-sleep kind #{name.inspect}")
      end
    end

    private def parse_byte_size(value : String, option : String) : Int64
      text = value.strip
      match = text.match(/\A(?<number>\d+(?:\.\d+)?)(?<unit>[kmgt]?i?b?|bytes?)?\z/i)
      unless match
        raise UsageError.new("invalid #{option} size #{value.inspect}")
      end
      number = match["number"].to_f64
      unit = (match["unit"]? || "").downcase
      multiplier = case unit
                   when "", "b", "byte", "bytes" then 1_i64
                   when "k", "kb"                then 1_000_i64
                   when "ki", "kib"              then 1_i64 << 10
                   when "m", "mb"                then 1_000_000_i64
                   when "mi", "mib"              then 1_i64 << 20
                   when "g", "gb"                then 1_000_000_000_i64
                   when "gi", "gib"              then 1_i64 << 30
                   when "t", "tb"                then 1_000_000_000_000_i64
                   when "ti", "tib"              then 1_i64 << 40
                   else
                     raise UsageError.new("invalid #{option} size unit #{unit.inspect}")
                   end
      (number * multiplier).round.to_i64
    end

    def extract_info(url : String, download = true) : Info
      extractor = extractor_for(url)
      info = extractor.extract(url)
      process_extracted_info(info, download)
    ensure
      @cookie_jar.try(&.save)
    end

    def load_info(download = true) : Info
      path = @options.string?("load_info_filename") ||
             raise UsageError.new("--load-info-json requires a file")
      info = Info.parse(File.read(path))
      process_extracted_info(info, download)
    rescue error : JSON::ParseException
      raise UsageError.new("Invalid info JSON: #{error.message}", cause: error)
    rescue error : File::Error
      raise UsageError.new("Unable to read info JSON: #{error.message}", cause: error)
    ensure
      @cookie_jar.try(&.save)
    end

    private def process_extracted_info(info : Info, download : Bool) : Info
      run_metadata_stage("pre_process", info)
      run_exec_stage("pre_process", info)
      run_metadata_stage("after_filter", info)
      if reason = rejection_reason(info, include_filesize: false)
        return reject_info(info, reason)
      end
      run_sponsorblock(info)
      run_exec_stage("after_filter", info)
      return process_playlist(info, download) if info.string?("_type").in?("playlist", "multi_video")
      select_subtitles(info)
      selected = select_formats(info)
      selected.each { |selected_info| validate_info!(selected_info) }
      primary = selected.first
      if reason = rejection_reason(primary, include_filesize: true)
        return reject_info(primary, reason)
      end
      if archived?(primary)
        primary.sidecar["archive_status"] = ArchiveStatus.new(true)
        info_log("[download] #{primary.id} has already been recorded in the archive")
        return attach_format_selections(primary, selected)
      end

      if download
        selected.each { |selected_info| process_info(selected_info, run_after_video: false) }
        run_metadata_stage("after_video", primary)
        run_exec_stage("after_video", primary)
      elsif @options.bool?("force_write_download_archive")
        record_download_archive(primary)
      end
      attach_format_selections(primary, selected)
    end

    def download(urls : Enumerable(String)) : Int32
      errors = 0
      if @options.string?("load_info_filename")
        begin
          media_download = !simulate?
          info = load_info(download: media_download)
          return 0 if rejected?(info)
          process_sidecars(info) if !media_download && sidecars_only?
          print_info(info)
          return 0 if archived?(info) && @options.bool?("break_on_existing")
        rescue error : Error
          errors += 1
          @error.puts("ERROR: #{error.message}")
          return 1 unless @options.bool?("ignoreerrors")
        end
      end
      urls.each do |url|
        previous_limit_base = @download_limit_base
        @download_limit_base = @num_downloads if break_per_input?
        begin
          break if max_downloads_reached?
          begin
            media_download = !simulate?
            info = extract_info(url, download: media_download)
            if rejected?(info)
              break if break_queue_for_rejection?(info)
              next
            end
            process_sidecars(info) if !media_download && sidecars_only?
            print_info(info)
            break if download_break?(info) && !break_per_input?
            if archived?(info) && @options.bool?("break_on_existing")
              break unless break_per_input?
            end
            break if max_downloads_reached? && !break_per_input?
          rescue error : Error
            errors += 1
            @error.puts("ERROR: #{error.message}")
            break unless @options.bool?("ignoreerrors")
            next
          end
        ensure
          @download_limit_base = previous_limit_base
        end
      end
      errors == 0 ? 0 : 1
    end

    def process_info(info : Info, *, run_after_video = true) : Info
      @num_downloads += 1
      run_metadata_stage("video", info)
      run_exec_stage("video", info)
      filename = prepare_filename(info)
      info["_filename"] = filename
      write_subtitles(info, filename)
      write_thumbnails(info, filename)
      write_metadata_sidecars(info, filename)
      run_metadata_stage("before_dl", info)
      run_exec_stage("before_dl", info)
      if requested_formats = info.array?("requested_formats")
        download_requested_formats(info, filename, requested_formats)
        merger = @postprocessor_registry.build("FFmpegMerger", self)
        publish_postprocessor("started", merger, info)
        info = merger.run(info)
        publish_postprocessor("finished", merger, info)
      else
        sleep_for_media_download
        downloader = downloader_for(info)
        downloader.download(info, filename)
      end
      info["filepath"] = filename
      write_info_json(info, filename) if @options.bool?("writeinfojson")

      run_fixups(info)
      run_metadata_stage("post_process", info)
      info = run_media_postprocessors(info)
      if convert_subtitles?
        converter = @postprocessor_registry.build("FFmpegSubtitlesConvertor", self)
        publish_postprocessor("started", converter, info)
        info = converter.run(info)
        publish_postprocessor("finished", converter, info)
      end
      if convert_thumbnails?
        converter = @postprocessor_registry.build("FFmpegThumbnailsConvertor", self)
        publish_postprocessor("started", converter, info)
        info = converter.run(info)
        publish_postprocessor("finished", converter, info)
      end
      if @options.bool?("embedsubtitles")
        embedder = @postprocessor_registry.build("FFmpegEmbedSubtitle", self)
        publish_postprocessor("started", embedder, info)
        info = embedder.run(info)
        publish_postprocessor("finished", embedder, info)
      end
      if modify_chapters?
        processor = @postprocessor_registry.build("ModifyChapters", self)
        publish_postprocessor("started", processor, info)
        info = processor.run(info)
        publish_postprocessor("finished", processor, info)
      end
      processors = @postprocessors.empty? ? [@postprocessor_registry.build("Metadata", self)] : @postprocessors
      processors.each do |processor|
        publish_postprocessor("started", processor, info)
        info = processor.run(info)
        publish_postprocessor("finished", processor, info)
      end
      if metadata_postprocessing?
        processor = @postprocessor_registry.build("FFmpegMetadata", self)
        publish_postprocessor("started", processor, info)
        info = processor.run(info)
        publish_postprocessor("finished", processor, info)
      end
      if @options.bool?("embedthumbnail")
        embedder = @postprocessor_registry.build("EmbedThumbnail", self)
        publish_postprocessor("started", embedder, info)
        info = embedder.run(info)
        publish_postprocessor("finished", embedder, info)
      end
      if @options.bool?("split_chapters") == true
        processor = @postprocessor_registry.build("FFmpegSplitChapters", self)
        publish_postprocessor("started", processor, info)
        info = processor.run(info)
        publish_postprocessor("finished", processor, info)
      end
      if @options.bool?("xattrs") == true
        processor = @postprocessor_registry.build("XAttrMetadata", self)
        publish_postprocessor("started", processor, info)
        info = processor.run(info)
        publish_postprocessor("finished", processor, info)
      end
      run_exec_stage("post_process", info)
      mover = @postprocessor_registry.build("MoveFiles", self)
      publish_postprocessor("started", mover, info)
      info = mover.run(info)
      publish_postprocessor("finished", mover, info)
      run_metadata_stage("after_move", info)
      run_exec_stage("after_move", info)
      if run_after_video
        run_metadata_stage("after_video", info)
        run_exec_stage("after_video", info)
      end
      final_path = info.string?("filepath") || filename
      info["requested_downloads"] = JSON::Any.new([
        JSON::Any.new({
          "filepath" => JSON::Any.new(final_path),
          "ext"      => JSON::Any.new(info.ext),
        }),
      ])
      record_download_archive(info)
      info
    end

    def prepare_filename(info : Info) : String
      rendered = output_template_renderer.render(
        output_template,
        info,
        Math.max(1_i64, @num_downloads),
      )
      return rendered if rendered == "-"
      return rendered if Path.new(rendered).absolute?

      paths = @options.hash?("paths")
      home = paths.try(&.["home"]?).try(&.as_s?)
      temporary = paths.try(&.["temp"]?).try(&.as_s?)
      final_path = home ? File.join(home, rendered) : rendered
      return final_path unless temporary

      temporary_path = File.join(temporary, rendered)
      info.sidecar["move_plan"] = MovePlan.new(
        temporary,
        home || ".",
        final_path,
      )
      temporary_path
    end

    private def extractor_for(url : String) : Extractor
      @extractor_instances.each_value do |extractor|
        return extractor if extractor_allowed?(extractor.key, extractor.name) && extractor.suitable?(url)
      end
      if @options.bool?("force_generic_extractor") == true
        extractor = @extractor_registry.build("Generic", self)
        if extractor.suitable?(url) && extractor_allowed?(extractor.key, extractor.name)
          @extractor_instances[extractor.key] = extractor
          return extractor
        end
      end

      extractor = nil.as(Extractor?)
      @extractor_registry.registrations.each do |registration|
        next unless extractor_allowed?(registration.key, registration.name)
        candidate = registration.factory.call(self)
        if candidate.suitable?(url)
          extractor = candidate
          break
        end
      end
      extractor ||= raise UnsupportedUrlError.new(url)
      @extractor_instances[extractor.key] = extractor
      extractor
    end

    private def extractor_allowed?(key : String, name : String) : Bool
      allowed = @options.array?("allowed_extractors").try(&.compact_map(&.as_s?)) || [] of String
      return true if allowed.empty? || allowed.any? { |entry| entry.downcase.in?("all", "default") }
      allowed.any? do |entry|
        pattern = entry.downcase
        key.downcase == pattern || name.downcase == pattern
      end
    end

    private def process_playlist(playlist : Info, download : Bool) : Info
      all_entries = playlist.array?("entries") || [] of JSON::Any
      entries = select_playlist_entries(all_entries)
      processed = [] of JSON::Any
      entries.each_with_index do |entry, offset|
        info = Info.new(entry.as_h.dup)
        playlist_index = (info.int?("__playlist_index") || offset + 1).to_i
        info.delete("__playlist_index")
        inherit_playlist_fields(playlist, info, playlist_index, all_entries.size)
        run_metadata_stage("pre_process", info)
        run_metadata_stage("after_filter", info)
        if reason = rejection_reason(info, include_filesize: false)
          reject_info(info, reason)
          if should_break_on_rejection?(info)
            mark_download_break(playlist)
            break
          end
          next
        end
        break if max_downloads_reached?
        run_sponsorblock(info)
        select_subtitles(info)
        selected = select_formats(info)
        selected.each { |selected_info| validate_info!(selected_info) }
        primary = selected.first
        if reason = rejection_reason(primary, include_filesize: true)
          reject_info(primary, reason)
          if should_break_on_rejection?(primary)
            mark_download_break(playlist)
            break
          end
          next
        end
        if archived?(primary)
          primary.sidecar["archive_status"] = ArchiveStatus.new(true)
          processed << JSON::Any.new(primary.data)
          if @options.bool?("break_on_existing")
            mark_download_break(playlist)
            break
          end
          next
        end
        if download
          selected.each { |selected_info| process_info(selected_info, run_after_video: false) }
          run_metadata_stage("after_video", primary)
          run_exec_stage("after_video", primary)
        end
        record_download_archive(primary) if !download && @options.bool?("force_write_download_archive")
        processed << JSON::Any.new(primary.data)
      rescue error : Error
        raise error unless @options.bool?("ignoreerrors")
        @error.puts("ERROR: #{error.message}")
      end
      playlist["entries"] = JSON::Any.new(processed)
      playlist["playlist_count"] = all_entries.size
      if concatenate_playlist?(playlist, download)
        processor = @postprocessor_registry.build("FFmpegConcat", self)
        publish_postprocessor("started", processor, playlist)
        playlist = processor.run(playlist)
        publish_postprocessor("finished", processor, playlist)
      end
      run_metadata_stage("playlist", playlist)
      run_exec_stage("playlist", playlist)
      playlist
    end

    private def select_playlist_entries(entries : Array(JSON::Any)) : Array(JSON::Any)
      indexed = entries.each_with_index.map { |entry, index| {entry, index + 1} }.to_a
      if item_spec = @options.string?("playlist_items")
        selected = parse_playlist_items(item_spec, entries.size).to_set
        indexed.select! { |_, index| selected.includes?(index) }
      else
        start_index = Math.max(1_i64, @options.int?("playliststart") || 1).to_i
        end_index = (@options.int?("playlistend") || entries.size).to_i
        indexed.select! { |_, index| start_index <= index <= end_index }
      end
      indexed = indexed.first(1) if @options.bool?("noplaylist") == true
      indexed.reverse! if @options.bool?("playlist_reverse")
      indexed.shuffle! if @options.bool?("playlist_random")
      indexed.map do |entry, index|
        values = entry.as_h.dup
        values["__playlist_index"] = JSON::Any.new(index.to_i64)
        JSON::Any.new(values)
      end
    end

    private def concatenate_playlist?(playlist : Info, download : Bool) : Bool
      return false unless download
      policy = @options.string?("concat_playlist") || "multi_video"
      unless policy.in?("never", "always", "multi_video")
        raise UsageError.new("Invalid playlist concatenation policy #{policy.inspect}")
      end
      policy == "always" || (policy == "multi_video" && playlist.string?("_type") == "multi_video")
    end

    private def parse_playlist_items(spec : String, count : Int32) : Array(Int32)
      indices = [] of Int32
      spec.split(',').each do |part|
        token = part.strip
        next if token.empty?
        if token.includes?(':')
          pieces = token.split(':', remove_empty: false)
          start_value = playlist_index(pieces[0]?, count) || 1
          stop_value = playlist_index(pieces[1]?, count) || count
          step = pieces[2]?.try(&.to_i?) || 1
          raise UsageError.new("Playlist item step cannot be zero") if step == 0
          value = start_value
          while step > 0 ? value <= stop_value : value >= stop_value
            indices << value if 1 <= value <= count
            value += step
          end
        elsif match = token.match(/\A(-?\d+)-(-?\d+)\z/)
          start_value = playlist_index(match[1], count).not_nil!
          stop_value = playlist_index(match[2], count).not_nil!
          step = start_value <= stop_value ? 1 : -1
          value = start_value
          loop do
            indices << value if 1 <= value <= count
            break if value == stop_value
            value += step
          end
        elsif index = playlist_index(token, count)
          indices << index if 1 <= index <= count
        end
      end
      indices
    end

    private def playlist_index(value : String?, count : Int32) : Int32?
      return if value.nil? || value.empty?
      index = value.to_i?
      return unless index
      index < 0 ? count + index + 1 : index
    end

    private def inherit_playlist_fields(
      playlist : Info,
      info : Info,
      index : Int32,
      count : Int32,
    )
      %w[extractor extractor_key original_url webpage_url].each do |key|
        info[key] = playlist[key].not_nil! unless info.has_key?(key) || !playlist[key]?
      end
      info["playlist"] = playlist.title
      info["playlist_id"] = playlist.id
      info["playlist_title"] = playlist.title
      info["playlist_index"] = index
      info["playlist_count"] = count
    end

    private def build_cookie_jar : CookieJar?
      jar : CookieJar? = nil
      if spec = @options.string?("cookiesfrombrowser")
        jar = BrowserCookies.extract(spec)
      end
      if path = @options.string?("cookiefile")
        file_jar = CookieJar.load(path)
        if jar
          jar.absorb(file_jar)
        else
          jar = file_jar
        end
      end
      jar
    rescue error : RequestError | UsageError
      raise error
    rescue error
      raise RequestError.new("failed to load cookies", cause: error)
    end

    private def default_http_headers : Hash(String, String)
      headers = Networking::CrystalHttpHandler::DEFAULT_HEADERS.dup
      if user_agent = @options.string?("user_agent")
        headers["User-Agent"] = user_agent
      end
      if referer = @options.string?("referer")
        headers["Referer"] = referer
      end
      @options.hash?("headers").try do |custom|
        custom.each { |name, value| headers[name] = value.as_s }
      end
      headers
    end

    private def select_subtitles(info : Info)
      return unless subtitle_requested?
      selected = SubtitleSelector.select(info, @options)
      info["requested_subtitles"] = JSON::Any.new(selected)
    end

    private def subtitle_requested? : Bool
      @options.bool?("writesubtitles") == true ||
        @options.bool?("writeautomaticsub") == true ||
        @options.bool?("embedsubtitles") == true
    end

    private def write_subtitles(info : Info, media_filename : String)
      return unless subtitle_requested?
      subtitles = info.hash?("requested_subtitles")
      return unless subtitles && !subtitles.empty?

      base = subtitle_base_filename(info, media_filename)
      subtitles.each do |language, value|
        subtitle = value.as_h
        extension = subtitle["ext"]?.try(&.as_s?) || "vtt"
        filename = subtitle_filename(base, language, extension, info.ext)
        if File.exists?(filename) && @options.bool?("overwrites") != true
          subtitle["filepath"] = JSON::Any.new(filename)
          next
        end

        FileUtils.mkdir_p(Path.new(filename).parent)
        if data = subtitle["data"]?.try(&.as_s?)
          atomic_write_subtitle(filename, data)
        else
          download_subtitle(info, subtitle, filename)
        end
        subtitle["filepath"] = JSON::Any.new(filename)
      rescue error
        message = "Unable to download video subtitles for #{language.inspect}: #{error.message}"
        if @options.bool?("ignoreerrors")
          warning(message)
        else
          raise DownloadError.new(message, cause: error)
        end
      end
      info["requested_subtitles"] = JSON::Any.new(subtitles)
    end

    private def download_subtitle(
      info : Info,
      subtitle : Hash(String, JSON::Any),
      filename : String,
    )
      values = subtitle.dup
      %w[id title extractor extractor_key webpage_url original_url].each do |key|
        values[key] = info[key].not_nil! if !values.has_key?(key) && info[key]?
      end
      if !values.has_key?("http_headers") && (headers = info["http_headers"]?)
        values["http_headers"] = headers
      end
      subtitle_info = Info.new(values)
      protocol = subtitle_info.string?("protocol") ||
                 URI.parse(subtitle_info.url).scheme.presence ||
                 "http"
      sleep_for_subtitle
      @downloader_registry.build(protocol, self).download(subtitle_info, filename)
    end

    private def atomic_write_subtitle(filename : String, data : String)
      part = "#{filename}.part"
      File.write(part, data)
      File.delete?(filename)
      File.rename(part, filename)
    rescue error
      File.delete?(part) if part
      raise DownloadError.new("Unable to write #{filename}: #{error.message}", cause: error)
    end

    private def subtitle_base_filename(info : Info, media_filename : String) : String
      templates = @options["outtmpl"].try(&.as_h?)
      subtitle_template = templates.try(&.["subtitle"]?).try(&.as_s?)
      paths = @options.hash?("paths")
      subtitle_path = paths.try(&.["subtitle"]?).try(&.as_s?)
      return media_filename unless subtitle_template || subtitle_path

      template = subtitle_template || output_template
      rendered = output_template_renderer.render(
        template,
        info,
        Math.max(1_i64, @num_downloads),
      )
      root = subtitle_path || paths.try(&.["home"]?).try(&.as_s?)
      root && !Path.new(rendered).absolute? ? File.join(root, rendered) : rendered
    end

    private def subtitle_filename(
      filename : String,
      language : String,
      subtitle_extension : String,
      media_extension : String,
    ) : String
      extension = Path.new(filename).extension
      expected = ".#{media_extension}"
      stem = if !extension.empty? && extension.downcase == expected.downcase
               filename.rchop(extension)
             elsif extension.empty?
               filename
             else
               filename.rchop(extension)
             end
      safe_language = language.gsub(/[\\\/:*?"<>|]+/, "_")
      "#{stem}.#{safe_language}.#{subtitle_extension}"
    end

    private def convert_subtitles? : Bool
      target = @options.string?("convertsubtitles")
      !target.nil? && target != "none" && subtitle_requested?
    end

    private def thumbnail_requested? : Bool
      value = @options["writethumbnail"]
      value.try(&.as_bool?) == true ||
        value.try(&.as_s?) == "all" ||
        @options.bool?("embedthumbnail") == true
    end

    private def write_all_thumbnails? : Bool
      @options.string?("writethumbnail") == "all"
    end

    private def write_thumbnails(info : Info, media_filename : String)
      return unless thumbnail_requested?
      thumbnails = thumbnail_entries(info)
      return if thumbnails.empty?

      base = thumbnail_base_filename(info, media_filename)
      multiple = write_all_thumbnails? && thumbnails.size > 1
      candidates = thumbnails.each_with_index.to_a.reverse
      candidates.each do |thumbnail, index|
        values = thumbnail.as_h
        extension = thumbnail_extension(values)
        identifier = values["id"]?.try(&.as_s?) || index.to_s
        file_extension = multiple ? "#{safe_thumbnail_id(identifier)}.#{extension}" : extension
        filename = replace_media_extension(base, file_extension, info.ext)

        if File.exists?(filename) && @options.bool?("overwrites") != true
          values["filepath"] = JSON::Any.new(filename)
          break unless write_all_thumbnails?
          next
        end

        begin
          download_thumbnail(info, values, filename)
          values["filepath"] = JSON::Any.new(filename)
          break unless write_all_thumbnails?
        rescue error
          warning("Unable to download thumbnail #{identifier}: #{error.message}")
          next
        end
      end
      info["thumbnails"] = JSON::Any.new(thumbnails)
    end

    private def thumbnail_entries(info : Info) : Array(JSON::Any)
      thumbnails = info.array?("thumbnails")
      return thumbnails unless thumbnails.nil? || thumbnails.empty?
      url = info.string?("thumbnail")
      return [] of JSON::Any unless url
      [JSON::Any.new({"url" => JSON::Any.new(url)})]
    end

    private def download_thumbnail(
      info : Info,
      thumbnail : Hash(String, JSON::Any),
      filename : String,
    )
      url = thumbnail["url"]?.try(&.as_s?) ||
            raise DownloadError.new("Thumbnail is missing URL")
      headers = Hash(String, String).new
      source_headers = thumbnail["http_headers"]?.try(&.as_h?) || info.hash?("http_headers")
      source_headers.try do |values|
        values.each { |name, value| headers[name] = value.as_s }
      end

      FileUtils.mkdir_p(Path.new(filename).parent)
      part = "#{filename}.part"
      File.delete?(part)
      File.open(part, "wb") do |output|
        download_request(Networking::Request.new(url, headers: headers), rate_limited_io(output))
      end
      File.delete?(filename)
      File.rename(part, filename)
    rescue error
      File.delete?(part) if part
      raise error
    end

    private def thumbnail_extension(thumbnail : Hash(String, JSON::Any)) : String
      extension = thumbnail["ext"]?.try(&.as_s?)
      extension ||= thumbnail["url"]?.try(&.as_s?).try { |url| Manifest.extension(url, "jpg") }
      extension = "jpg" if extension.nil? || extension == "unknown_video"
      extension == "jpeg" ? "jpg" : extension
    end

    private def thumbnail_base_filename(info : Info, media_filename : String) : String
      templates = @options["outtmpl"].try(&.as_h?)
      thumbnail_template = templates.try(&.["thumbnail"]?).try(&.as_s?)
      paths = @options.hash?("paths")
      thumbnail_path = paths.try(&.["thumbnail"]?).try(&.as_s?)
      return media_filename unless thumbnail_template || thumbnail_path

      template = thumbnail_template || output_template
      rendered = output_template_renderer.render(
        template,
        info,
        Math.max(1_i64, @num_downloads),
      )
      root = thumbnail_path || paths.try(&.["home"]?).try(&.as_s?)
      root && !Path.new(rendered).absolute? ? File.join(root, rendered) : rendered
    end

    private def replace_media_extension(
      filename : String,
      new_extension : String,
      media_extension : String,
    ) : String
      extension = Path.new(filename).extension
      expected = ".#{media_extension}"
      stem = if !extension.empty? && extension.downcase == expected.downcase
               filename.rchop(extension)
             elsif extension.empty?
               filename
             else
               filename.rchop(extension)
             end
      "#{stem}.#{new_extension}"
    end

    private def safe_thumbnail_id(identifier : String) : String
      identifier.gsub(/[\\\/:*?"<>|]+/, "_")
    end

    private def convert_thumbnails? : Bool
      target = @options.string?("convertthumbnails")
      !target.nil? && target != "none" && thumbnail_requested?
    end

    private def metadata_sidecar_requested? : Bool
      @options.bool?("writedescription") == true ||
        @options.bool?("writelink") == true ||
        @options.bool?("writeurllink") == true ||
        @options.bool?("writewebloclink") == true ||
        @options.bool?("writedesktoplink") == true
    end

    private def write_metadata_sidecars(info : Info, media_filename : String)
      return unless metadata_sidecar_requested?
      if @options.bool?("writedescription") == true
        path = sidecar_filename(media_filename, "description")
        write_text_sidecar(info, path, info.string?("description") || "")
      end

      url = link_url(info)
      if @options.bool?("writelink") == true
        write_platform_link_sidecar(info, media_filename, url)
      end
      write_url_link_sidecar(info, media_filename, url) if @options.bool?("writeurllink") == true
      write_webloc_link_sidecar(info, media_filename, url) if @options.bool?("writewebloclink") == true
      write_desktop_link_sidecar(info, media_filename, url) if @options.bool?("writedesktoplink") == true
    end

    private def write_platform_link_sidecar(info : Info, media_filename : String, url : String)
      {% if flag?(:win32) %}
        write_url_link_sidecar(info, media_filename, url)
      {% elsif flag?(:darwin) %}
        write_webloc_link_sidecar(info, media_filename, url)
      {% else %}
        write_desktop_link_sidecar(info, media_filename, url)
      {% end %}
    end

    private def write_url_link_sidecar(info : Info, media_filename : String, url : String)
      write_text_sidecar(info, sidecar_filename(media_filename, "url"), "[InternetShortcut]\nURL=#{url}\n")
    end

    private def write_webloc_link_sidecar(info : Info, media_filename : String, url : String)
      content = <<-XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>URL</key>
        <string>#{xml_escape(url)}</string>
      </dict>
      </plist>
      XML
      write_text_sidecar(info, sidecar_filename(media_filename, "webloc"), content)
    end

    private def write_desktop_link_sidecar(info : Info, media_filename : String, url : String)
      title = info.string?("title") || info.id
      content = <<-DESKTOP
      [Desktop Entry]
      Type=Link
      Name=#{desktop_escape(title)}
      URL=#{desktop_escape(url)}
      DESKTOP
      write_text_sidecar(info, sidecar_filename(media_filename, "desktop"), content)
    end

    private def write_text_sidecar(info : Info, path : String, content : String)
      if File.exists?(path) && @options.bool?("overwrites") != true
        register_extra_sidecar(info, path)
        return
      end
      FileUtils.mkdir_p(Path.new(path).parent)
      part = "#{path}.part"
      File.write(part, content)
      File.delete?(path)
      File.rename(part, path)
      register_extra_sidecar(info, path)
    rescue error
      File.delete?(part) if part
      raise DownloadError.new("Unable to write #{path}: #{error.message}", cause: error)
    end

    private def register_extra_sidecar(info : Info, path : String)
      sidecars = info.sidecar["extra_sidecar_files"]?.as?(ExtraSidecarFiles)
      unless sidecars
        sidecars = ExtraSidecarFiles.new
        info.sidecar["extra_sidecar_files"] = sidecars
      end
      sidecars.add(path)
    end

    private def sidecar_filename(media_filename : String, extension : String) : String
      current = Path.new(media_filename).extension
      stem = current.empty? ? media_filename : media_filename.rchop(current)
      "#{stem}.#{extension}"
    end

    private def link_url(info : Info) : String
      info.string?("webpage_url") || info.string?("original_url") || info.url
    end

    private def xml_escape(value : String) : String
      value.gsub("&", "&amp;")
        .gsub("<", "&lt;")
        .gsub(">", "&gt;")
        .gsub("\"", "&quot;")
        .gsub("'", "&apos;")
    end

    private def desktop_escape(value : String) : String
      value.gsub("\\", "\\\\").gsub("\n", "\\n")
    end

    private def sidecars_only? : Bool
      @options.bool?("skip_download") == true &&
        @options.bool?("simulate") != true &&
        (subtitle_requested? || thumbnail_requested? || metadata_sidecar_requested? ||
          @options.bool?("writeinfojson") == true)
    end

    private def process_sidecars(info : Info)
      if info.string?("_type") == "playlist"
        info.array?("entries").try do |entries|
          entries.each { |entry| process_sidecars(Info.new(entry.as_h)) }
        end
        return
      end
      if selections = info.sidecar["format_selections"]?.as?(FormatSelections)
        selections.infos.each { |selected| process_sidecars(selected) }
        return
      end

      @num_downloads += 1
      filename = prepare_filename(info)
      info["_filename"] = filename
      write_subtitles(info, filename)
      write_thumbnails(info, filename)
      write_metadata_sidecars(info, filename)
      if convert_subtitles?
        converter = @postprocessor_registry.build("FFmpegSubtitlesConvertor", self)
        publish_postprocessor("started", converter, info)
        converter.run(info)
        publish_postprocessor("finished", converter, info)
      end
      if convert_thumbnails?
        converter = @postprocessor_registry.build("FFmpegThumbnailsConvertor", self)
        publish_postprocessor("started", converter, info)
        converter.run(info)
        publish_postprocessor("finished", converter, info)
      end
      if info.sidecar["move_plan"]?
        info["filepath"] = filename
        mover = @postprocessor_registry.build("MoveFiles", self)
        publish_postprocessor("started", mover, info)
        info = mover.run(info)
        publish_postprocessor("finished", mover, info)
      end
      final_filename = info.string?("filepath") || filename
      write_info_json(info, final_filename) if @options.bool?("writeinfojson")
    end

    private def run_media_postprocessors(info : Info) : Info
      keys = [] of String
      keys << "FFmpegExtractAudio" if @options.bool?("extractaudio") == true
      keys << "FFmpegVideoRemuxer" if @options.string?("remuxvideo")
      keys << "FFmpegVideoConvertor" if @options.string?("recodevideo")
      keys.each do |key|
        processor = @postprocessor_registry.build(key, self)
        publish_postprocessor("started", processor, info)
        info = processor.run(info)
        publish_postprocessor("finished", processor, info)
      end
      info
    end

    private def metadata_postprocessing? : Bool
      embed_infojson = @options["embed_infojson"]
      @options.bool?("addmetadata") == true ||
        @options.bool?("addchapters") == true ||
        !(@options.array?("sponsorblock_mark") || [] of JSON::Any).empty? ||
        embed_infojson.try(&.as_bool?) == true ||
        !embed_infojson.try(&.as_s?).nil?
    end

    private def modify_chapters? : Bool
      !(@options.array?("remove_chapters") || [] of JSON::Any).empty? ||
        !(@options.array?("sponsorblock_remove") || [] of JSON::Any).empty?
    end

    private def run_sponsorblock(info : Info)
      return if @options.bool?("no_sponsorblock") == true
      categories = (@options.array?("sponsorblock_mark") || [] of JSON::Any) +
                   (@options.array?("sponsorblock_remove") || [] of JSON::Any)
      return if categories.empty?

      processor = @postprocessor_registry.build("SponsorBlock", self)
      publish_postprocessor("started", processor, info)
      processor.run(info)
      publish_postprocessor("finished", processor, info)
    end

    private def run_exec_stage(stage : String, info : Info)
      commands = [] of String
      @options.hash?("exec_cmd").try do |stages|
        value = stages[stage]?
        if entries = value.try(&.as_a?)
          commands.concat(entries.compact_map(&.as_s?))
        elsif command = value.try(&.as_s?)
          commands << command
        end
      end
      if stage == "before_dl"
        @options.array?("exec_before_dl_cmd").try do |entries|
          commands.concat(entries.compact_map(&.as_s?))
        end
      end
      return if commands.empty?

      processor = ExecPostProcessor.new(self, commands)
      publish_postprocessor("started", processor, info)
      processor.run(info)
      publish_postprocessor("finished", processor, info)
    end

    private def run_metadata_stage(stage : String, info : Info)
      actions = [] of JSON::Any
      @options.hash?("parse_metadata").try do |stages|
        actions.concat(stages[stage]?.try(&.as_a?) || [] of JSON::Any)
      end
      if stage == "pre_process"
        if format = @options.string?("metafromtitle")
          actions << JSON::Any.new({
            "type"   => JSON::Any.new("interpret"),
            "input"  => JSON::Any.new("title"),
            "output" => JSON::Any.new(format),
          })
        end
      end
      return if actions.empty?

      processor = MetadataParserPostProcessor.new(self, actions)
      publish_postprocessor("started", processor, info)
      processor.run(info)
      publish_postprocessor("finished", processor, info)
    end

    private def archived?(info : Info) : Bool
      status = info.sidecar["archive_status"]?.as?(ArchiveStatus)
      return status.skipped if status
      @download_archive.try(&.includes?(info)) || false
    end

    private def rejected?(info : Info) : Bool
      !info.sidecar["download_rejection"]?.as?(DownloadRejection).nil?
    end

    private def mark_download_break(info : Info)
      info.sidecar["download_break"] = DownloadBreak.new
    end

    private def download_break?(info : Info) : Bool
      !info.sidecar["download_break"]?.as?(DownloadBreak).nil?
    end

    private def should_break_on_rejection?(info : Info) : Bool
      @options.bool?("break_on_reject") == true || download_break?(info)
    end

    private def break_queue_for_rejection?(info : Info) : Bool
      should_break_on_rejection?(info) && !break_per_input?
    end

    private def break_per_input? : Bool
      @options.bool?("break_per_url") == true
    end

    private def reject_info(info : Info, reason : String) : Info
      info.sidecar["download_rejection"] = DownloadRejection.new(reason)
      info_log("[download] #{info.id}: #{reason}")
      info
    end

    private def max_downloads_reached? : Bool
      limit = @options.int?("max_downloads")
      return false unless limit
      (@num_downloads - @download_limit_base) >= Math.max(0_i64, limit)
    end

    private def rejection_reason(info : Info, *, include_filesize : Bool) : String?
      title = info.string?("title") || ""
      if pattern = @options.string?("matchtitle")
        regex = compile_filter_regex(pattern, "--match-title")
        return "title did not match #{pattern.inspect}" unless title.matches?(regex)
      end
      if pattern = @options.string?("rejecttitle")
        regex = compile_filter_regex(pattern, "--reject-title")
        return "title matched reject pattern #{pattern.inspect}" if title.matches?(regex)
      end

      if minimum = @options.int?("min_views")
        views = info.int?("view_count")
        return "view count is unavailable" unless views
        return "view count #{views} is lower than #{minimum}" if views < minimum
      end
      if maximum = @options.int?("max_views")
        views = info.int?("view_count")
        return "view count is unavailable" unless views
        return "view count #{views} is higher than #{maximum}" if views > maximum
      end
      if allowed_age = @options.int?("age_limit")
        actual_age = info.int?("age_limit")
        return "age limit #{actual_age} exceeds #{allowed_age}" if actual_age && actual_age > allowed_age
      end

      if expected = @options.string?("date")
        expected_date = parse_filter_date(expected, "--date")
        upload_date = info_upload_date(info)
        return "upload date is unavailable" unless upload_date
        return "upload date #{upload_date} is not #{expected_date}" unless upload_date == expected_date
      end
      if lower = @options.string?("dateafter")
        lower_date = parse_filter_date(lower, "--dateafter")
        upload_date = info_upload_date(info)
        return "upload date is unavailable" unless upload_date
        return "upload date #{upload_date} is before #{lower_date}" if upload_date < lower_date
      end
      if upper = @options.string?("datebefore")
        upper_date = parse_filter_date(upper, "--datebefore")
        upload_date = info_upload_date(info)
        return "upload date is unavailable" unless upload_date
        return "upload date #{upload_date} is after #{upper_date}" if upload_date > upper_date
      end

      return unless include_filesize
      filesize = info.int?("filesize") || info.int?("filesize_approx")
      if minimum = @options.string?("min_filesize")
        bytes = parse_size_filter(minimum, "--min-filesize")
        return "filesize is unavailable" unless filesize
        return "filesize #{filesize} is lower than #{bytes}" if filesize < bytes
      end
      if maximum = @options.string?("max_filesize")
        bytes = parse_size_filter(maximum, "--max-filesize")
        return "filesize is unavailable" unless filesize
        return "filesize #{filesize} is higher than #{bytes}" if filesize > bytes
      end
      if include_filesize
        if reason = match_filter_rejection_reason(info)
          return reason
        end
        if reason = match_filter_rejection_reason(info, "breaking_match_filter", "break match filters")
          mark_download_break(info)
          return reason
        end
      end
      nil
    end

    private def match_filter_rejection_reason(
      info : Info,
      option = "match_filter",
      label = "match filters",
    ) : String?
      filters = @options.array?(option).try(&.compact_map(&.as_s?)) || [] of String
      filters = filters.map(&.strip).reject(&.empty?)
      return if filters.empty?

      reasons = [] of String
      filters.each do |expression|
        reason = match_filter_expression_rejection(info, expression)
        return nil unless reason
        reasons << reason
      end
      "did not pass #{label}: #{reasons.join("; ")}"
    end

    private def match_filter_expression_rejection(info : Info, expression : String) : String?
      alternatives = split_filter_expression(expression, '|')
      alternatives = [expression] if alternatives.empty?
      reasons = [] of String
      alternatives.each do |alternative|
        terms = split_filter_expression(alternative, '&')
        terms = [alternative] if terms.empty?
        term_reasons = terms.compact_map do |term|
          term = term.strip
          next if term.empty?
          match_filter_term_rejection(info, term)
        end
        return nil if term_reasons.empty?
        reasons << term_reasons.join(", ")
      end
      reasons.join(" or ")
    end

    private def split_filter_expression(expression : String, separator : Char) : Array(String)
      parts = [] of String
      buffer = String::Builder.new
      quote = nil.as(Char?)
      escaped = false
      expression.each_char do |char|
        if escaped
          buffer << char
          escaped = false
          next
        end
        if char == '\\'
          buffer << char
          escaped = true
          next
        end
        if quote
          quote = nil if char == quote
          buffer << char
          next
        end
        if char == '"' || char == '\''
          quote = char
          buffer << char
          next
        end
        if char == separator
          parts << buffer.to_s.strip
          buffer = String::Builder.new
        else
          buffer << char
        end
      end
      parts << buffer.to_s.strip
      parts.reject(&.empty?)
    end

    private def match_filter_term_rejection(info : Info, term : String) : String?
      if match = term.match(/\A\s*(!)?([\w.-]+)\s*\z/)
        negate = !match[1]?.nil?
        value = info_field(info, match[2])
        present = filter_present?(value)
        matched = negate ? !present : present
        return nil if matched
        return negate ? "#{match[2]} is present" : "#{match[2]} is missing"
      end

      if match = term.match(/\A\s*([\w.-]+)\s*(<=|>=|!=|=|<|>)\s*(\?)?\s*([0-9.]+(?:[kKmMgGtTpPeEzZyY]i?[Bb]?)?)\s*\z/)
        field = match[1]
        value = info_field(info, field)
        return nil if missing_allowed?(value, match[3]?)
        number = filter_number(value)
        return "#{field} is not numeric" unless number
        expected = parse_match_filter_number(match[4])
        return nil if compare_filter_numbers(number, expected, match[2])
        return "#{field} #{number} does not satisfy #{match[2]} #{expected}"
      end

      if match = term.match(/\A\s*([\w.-]+)\s*(!)?(\^=|\$=|\*=|~=|=)\s*(\?)?\s*(?:"((?:\\.|[^"])*)"|'((?:\\.|[^'])*)'|([^\s]+))\s*\z/)
        field = match[1]
        value = info_field(info, field)
        return nil if missing_allowed?(value, match[4]?)
        actual = filter_string(value)
        return "#{field} is not string-like" unless actual
        expected = unescape_match_filter_value(match[5]? || match[6]? || match[7])
        matched = case match[3]
                  when "="  then actual == expected
                  when "^=" then actual.starts_with?(expected)
                  when "$=" then actual.ends_with?(expected)
                  when "*=" then actual.includes?(expected)
                  when "~=" then Regex.new(expected).matches?(actual)
                  else           false
                  end
        matched = !matched if match[2]?
        return nil if matched
        return "#{field} #{actual.inspect} does not satisfy #{term.inspect}"
      end

      raise UsageError.new("Invalid match filter specification: #{term}")
    rescue error : Regex::Error
      raise UsageError.new("Invalid regular expression in match filter: #{term}", cause: error)
    end

    private def info_field(info : Info, path : String) : JSON::Any?
      current = JSON::Any.new(info.data)
      path.split('.').each do |part|
        return nil if part.empty?
        if hash = current.as_h?
          current = hash[part]? || return nil
        elsif array = current.as_a?
          index = part.to_i? || return nil
          current = array[index]? || return nil
        else
          return nil
        end
      end
      current
    end

    private def filter_present?(value : JSON::Any?) : Bool
      return false if value.nil? || value.raw.nil?
      bool = value.as_bool?
      return bool unless bool.nil?
      true
    end

    private def missing_allowed?(value : JSON::Any?, marker : String?) : Bool
      !marker.nil? && (value.nil? || value.raw.nil?)
    end

    private def filter_number(value : JSON::Any?) : Float64?
      return unless value
      value.as_f? || value.as_i64?.try(&.to_f64) || value.as_s?.try(&.to_f64?)
    end

    private def filter_string(value : JSON::Any?) : String?
      return unless value && !value.raw.nil?
      value.as_s? ||
        value.as_i64?.try(&.to_s) ||
        value.as_f?.try(&.to_s) ||
        value.as_bool?.try(&.to_s)
    end

    private def parse_match_filter_number(value : String) : Float64
      return value.to_f64 if value.matches?(/\A[0-9.]+\z/)
      match = value.match(/\A([0-9.]+)([kKmMgGtTpPeEzZyY])(i)?[Bb]?\z/) ||
              raise UsageError.new("Invalid numeric value in match filter: #{value}")
      units = "kMGTPEZY"
      exponent = units.downcase.index(match[2].downcase).not_nil! + 1
      base = match[3]? ? 1024_f64 : 1000_f64
      match[1].to_f64 * (base ** exponent)
    rescue error : ArgumentError
      raise UsageError.new("Invalid numeric value in match filter: #{value}", cause: error)
    end

    private def compare_filter_numbers(actual : Float64, expected : Float64, operator : String) : Bool
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

    private def unescape_match_filter_value(value : String) : String
      value.gsub(/\\([\\"'])/, "\\1")
    end

    private def compile_filter_regex(pattern : String, option : String) : Regex
      Regex.new(pattern)
    rescue error : ArgumentError
      raise UsageError.new("invalid #{option} regex #{pattern.inspect}: #{error.message}", cause: error)
    end

    private def info_upload_date(info : Info) : Int32?
      if upload_date = info.string?("upload_date") || info.string?("release_date")
        digits = upload_date.gsub(/[^0-9]/, "")
        return digits.to_i? if digits.size == 8
      end
      if timestamp = info.int?("timestamp")
        return Time.unix(timestamp).to_s("%Y%m%d").to_i
      end
      nil
    end

    private def parse_filter_date(value : String, option : String) : Int32
      digits = value.gsub(/[^0-9]/, "")
      unless digits.size == 8
        raise UsageError.new("invalid #{option} date #{value.inspect}; expected YYYYMMDD")
      end
      digits.to_i
    end

    private def parse_size_filter(value : String, option : String) : Int64
      text = value.strip
      match = text.match(/\A(?<number>\d+(?:\.\d+)?)(?<unit>[kmgt]?i?b?|bytes?)?\z/i)
      unless match
        raise UsageError.new("invalid #{option} size #{value.inspect}")
      end
      number = match["number"].to_f64
      unit = (match["unit"]? || "").downcase
      multiplier = case unit
                   when "", "b", "byte", "bytes" then 1_i64
                   when "k", "kb"                then 1_000_i64
                   when "ki", "kib"              then 1_i64 << 10
                   when "m", "mb"                then 1_000_000_i64
                   when "mi", "mib"              then 1_i64 << 20
                   when "g", "gb"                then 1_000_000_000_i64
                   when "gi", "gib"              then 1_i64 << 30
                   when "t", "tb"                then 1_000_000_000_000_i64
                   when "ti", "tib"              then 1_i64 << 40
                   else
                     raise UsageError.new("invalid #{option} size unit #{unit.inspect}")
                   end
      (number * multiplier).round.to_i64
    end

    private def run_fixups(info : Info)
      policy = @options.string?("fixup") || "detect_or_warn"
      unless policy.in?("ignore", "never", "warn", "detect_or_warn", "force")
        raise UsageError.new("Invalid fixup policy #{policy.inspect}")
      end
      return if policy.in?("ignore", "never")

      tasks = [] of Tuple(Bool, String, String)
      ratio = info.float?("stretched_ratio")
      tasks << {
        !ratio.nil? && ratio != 1.0,
        "Non-uniform pixel ratio #{ratio}",
        "FFmpegFixupStretched",
      }

      postprocessed_by_ffmpeg = !info.array?("requested_formats").nil?
      unless postprocessed_by_ffmpeg
        tasks << {
          info.ext == "m4a" && info.string?("container") == "m4a_dash",
          "writing DASH m4a. Only some players support this container",
          "FFmpegFixupM4a",
        }
        hls_fixup = info.ext.in?("mp4", "m4a") &&
                    info.protocol.starts_with?("m3u8") &&
                    @options.bool?("hls_use_mpegts") != true
        tasks << {
          hls_fixup,
          "Possible MPEG-TS in MP4 container or malformed AAC timestamps",
          "FFmpegFixupM3u8",
        }
        dash_fixup = info.protocol == "http_dash_segments" &&
                     (info.bool?("is_live") == true || info.bool?("is_dash_periods") == true)
        tasks << {
          dash_fixup,
          "Possible duplicate MOOV atoms",
          "FFmpegFixupDuplicateMoov",
        }
      end

      websocket_fixup = info.protocol.in?("websocket_frag", "web_socket_fragment")
      tasks << {websocket_fixup, "Malformed timestamps detected", "FFmpegFixupTimestamp"}
      tasks << {websocket_fixup, "Malformed duration detected", "FFmpegFixupDuration"}

      tasks.each do |condition, message, key|
        next unless condition
        if policy == "warn"
          warning("#{info.id}: #{message}")
          next
        end
        unless ffmpeg_available?
          warning("#{info.id}: #{message}. Install ffmpeg to fix this automatically")
          next
        end

        processor = @postprocessor_registry.build(key, self)
        publish_postprocessor("started", processor, info)
        processor.run(info)
        publish_postprocessor("finished", processor, info)
      end
    end

    private def ffmpeg_available? : Bool
      @process_runner.executable_available?(ffmpeg_path)
    end

    private def ffmpeg_path : String
      location = @options.string?("ffmpeg_location")
      return "ffmpeg" unless location
      return location unless File.directory?(location)
      executable = {{ flag?(:win32) ? "ffmpeg.exe" : "ffmpeg" }}
      File.join(location, executable)
    end

    private def record_download_archive(info : Info)
      @download_archive.try(&.record(info))
    end

    private def download_requested_formats(
      info : Info,
      filename : String,
      requested_formats : Array(JSON::Any),
    )
      paths = [] of String
      requested_formats.each_with_index do |format, index|
        values = format.as_h
        component = info.dup
        component.delete("requested_formats")
        component.merge!(values)
        component_path = component_filename(filename, component, index)
        component["_filename"] = component_path
        sleep_for_media_download
        downloader = downloader_for(component)
        downloader.download(component, component_path)
        paths << component_path
      end
      info.sidecar["merger_inputs"] = MergerInputs.new(paths)
    rescue error
      paths.try(&.each { |path| File.delete?(path) unless @options.bool?("keepvideo") })
      raise error
    end

    private def component_filename(filename : String, info : Info, index : Int32) : String
      extension = Path.new(filename).extension
      stem = extension.empty? ? filename : filename.rchop(extension)
      format_id = info.string?("format_id") || index.to_s
      safe_id = format_id.gsub(/[^0-9A-Za-z_-]+/, "_")
      "#{stem}.f#{safe_id}.#{info.ext}"
    end

    private def downloader_for(info : Info) : Downloader
      if command = external_downloader_for(info.protocol)
        return ExternalDownloader.new(self, command)
      end
      @downloader_registry.build(info.protocol, self)
    end

    def external_downloader_for(protocol : String) : String?
      entries = @options.hash?("external_downloader")
      return unless entries && !entries.empty?
      keys = external_downloader_keys(protocol)
      value = keys.compact_map { |key| entries[key]?.try(&.as_s?) }.first?
      value ||= entries["default"]?.try(&.as_s?)
      return unless value
      normalized = value.strip
      return if normalized.empty? || normalized.downcase == "native"
      normalized
    end

    private def external_downloader_keys(protocol : String) : Array(String)
      keys = [protocol]
      keys << "http" if protocol.in?("http", "https")
      keys << "m3u8" if protocol.starts_with?("m3u8")
      keys << "dash" if protocol == "http_dash_segments"
      keys.uniq
    end

    def external_downloader_arguments(command : String, info : Info, filename : String) : Array(String)
      extra = external_downloader_extra_arguments(command, info, filename)
      return extra if external_args_are_complete?(extra)

      case File.basename(command).downcase
      when "curl", "curl.exe"
        extra + ["-L", "--fail", "-o", filename, info.url]
      when "wget", "wget.exe"
        extra + ["-O", filename, info.url]
      when "aria2c", "aria2c.exe"
        directory = Path.new(filename).parent.to_s
        basename = Path.new(filename).basename
        extra + ["--allow-overwrite=true", "--auto-file-renaming=false", "-d", directory, "-o", basename, info.url]
      when "ffmpeg", "ffmpeg.exe"
        extra + ["-y", "-i", info.url, "-c", "copy", filename]
      else
        extra + ["-o", filename, info.url]
      end
    end

    private def external_downloader_extra_arguments(
      command : String,
      info : Info,
      filename : String,
    ) : Array(String)
      entries = @options.hash?("external_downloader_args")
      return [] of String unless entries && !entries.empty?
      basename = File.basename(command).downcase
      raw = entries[command]?.try(&.as_s?) ||
            entries[basename]?.try(&.as_s?) ||
            entries["default"]?.try(&.as_s?)
      return [] of String unless raw && !raw.empty?

      Config.tokenize(raw).map do |argument|
        expand_external_downloader_argument(argument, info, filename)
      end
    end

    private def expand_external_downloader_argument(
      argument : String,
      info : Info,
      filename : String,
    ) : String
      argument
        .gsub("{}", info.url)
        .gsub("{url}", info.url)
        .gsub("{filepath}", filename)
        .gsub("{filename}", filename)
        .gsub("{ext}", info.ext)
        .gsub("{id}", info.id)
    end

    private def external_args_are_complete?(arguments : Array(String)) : Bool
      return false if arguments.empty?
      has_url = false
      has_output = false
      arguments.each_with_index do |argument, index|
        has_url ||= argument.starts_with?("http://") ||
                    argument.starts_with?("https://") ||
                    argument.starts_with?("file:") ||
                    argument == "{}" ||
                    argument == "{url}"
        has_output ||= argument == "-o" ||
                       argument == "-O" ||
                       argument == "--output" ||
                       argument == "--output-document" ||
                       argument == "{filepath}" ||
                       argument == "{filename}" ||
                       (index > 0 && arguments[index - 1].in?("-o", "-O", "--output", "--output-document"))
      end
      has_url && has_output
    end

    private def validate_info!(info : Info)
      info.id
      info.title
      info.url
      info["webpage_url"] = info.string?("original_url") || info.url unless info.has_key?("webpage_url")
    end

    private def select_formats(info : Info) : Array(Info)
      mode = format_check_mode
      formats = info.formats
      availability = nil.as(FormatAvailabilityChecker?)

      if mode == "all"
        probe = FormatAvailabilityProbe.new(self, info, warning: false)
        if formats.empty?
          unless probe.working?(info.data)
            raise ExtractorError.new("Requested format is not available", true)
          end
        else
          working = formats.select { |format| probe.working?(format.as_h) }
          raise ExtractorError.new("Requested format is not available", true) if working.empty?
          info["formats"] = JSON::Any.new(working)
        end
      elsif mode == "selected"
        probe = FormatAvailabilityProbe.new(self, info)
        if formats.empty?
          unless probe.working?(info.data)
            raise ExtractorError.new("Requested format is not available", true)
          end
        else
          availability = ->(format : Hash(String, JSON::Any)) { probe.working?(format) }
        end
      elsif mode == "marked"
        probe = FormatAvailabilityProbe.new(self, info)
        marked = ->(format : Hash(String, JSON::Any)) do
          needs_testing = format["__needs_testing"]?.try(&.as_bool?) == true
          has_drm = format["has_drm"]?.try(&.as_bool?) == true
          !needs_testing && !has_drm || probe.working?(format)
        end
        if formats.empty?
          unless marked.call(info.data)
            raise ExtractorError.new("Requested format is not available", true)
          end
        else
          availability = marked
        end
      end

      expression = @options.string?("format")
      unless expression == "-" && !formats.empty? && @options.bool?("listformats") != true
        expression = nil if expression == "-"
        return select_format_expression(info, expression, availability)
      end

      print_formats(info, @error)
      loop do
        @error.print("\nEnter format selector (Press ENTER for default, or Ctrl+C to quit): ")
        @error.flush
        line = @input.gets ||
               raise UsageError.new("Interactive format selection input closed")
        requested = line.chomp
        requested = nil if requested.empty?
        begin
          return select_format_expression(info, requested, availability)
        rescue error : UsageError | ExtractorError
          @error.puts("ERROR: #{error.message}")
        end
      end
    end

    private def select_format_expression(
      info : Info,
      expression : String?,
      availability : FormatAvailabilityChecker?,
    ) : Array(Info)
      FormatSelector.select_all(
        info,
        expression,
        @options.string?("merge_output_format"),
        @options.bool?("allow_multiple_video_streams") == true,
        @options.bool?("allow_multiple_audio_streams") == true,
        @options.array?("format_sort").try { |values| values.compact_map(&.as_s?) } || [] of String,
        @options.bool?("format_sort_force") == true,
        @options.bool?("prefer_free_formats") == true,
        availability,
      )
    end

    private def format_check_mode : String
      value = @options["check_formats"]
      return "marked" if value.nil? || value.raw.nil?
      boolean = value.as_bool?
      unless boolean.nil?
        return boolean ? "all" : "none"
      end
      return "selected" if value.as_s? == "selected"
      raise UsageError.new("Invalid format availability check mode")
    end

    private def attach_format_selections(primary : Info, selected : Array(Info)) : Info
      primary.sidecar["format_selections"] = FormatSelections.new(selected) if selected.size > 1
      primary
    end

    private def output_template : String
      templates = @options["outtmpl"].try(&.as_h?)
      templates.try(&.["default"]?).try(&.as_s?) ||
        @options.string?("outtmpl") ||
        (@options.bool?("useid") == true ? "%(id)s.%(ext)s" : nil) ||
        "%(title)s [%(id)s].%(ext)s"
    end

    private def output_template_renderer : OutputTemplate
      OutputTemplate.new(
        na_placeholder: @options.string?("outtmpl_na_placeholder") || "NA",
        restrict_filenames: @options.bool?("restrictfilenames") == true,
        windows_filenames: @options.bool?("windowsfilenames"),
        trim_file_name: (@options.int?("trim_file_name") || 0).to_i,
        autonumber_start: @options.int?("autonumber_start") || 1_i64,
        autonumber_size: (@options.int?("autonumber_size") || 5).to_i,
      )
    end

    private def simulate? : Bool
      if simulate = @options.bool?("simulate")
        return simulate
      end
      return true if @options.bool?("skip_download")
      return true unless (@options.hash?("forceprint") || Hash(String, JSON::Any).new).empty?
      return true unless (@options.hash?("print_to_file") || Hash(String, JSON::Any).new).empty?
      %w[
        dump_single_json dumpjson forcejson print_json listformats listsubtitles list_thumbnails
        getid gettitle geturl getthumbnail getdescription getduration getfilename getformat
      ].any? { |option| @options.bool?(option) }
    end

    private def print_info(info : Info)
      if info.string?("_type") == "playlist"
        if @options.bool?("dump_single_json")
          print_single_info(info)
          return
        end
        print_templates(info, "playlist")
        info.array?("entries").try do |entries|
          entries.each { |entry| print_single_info(Info.new(entry.as_h)) }
        end
        return
      end
      if selections = info.sidecar["format_selections"]?.as?(FormatSelections)
        selections.infos.each { |selected| print_single_info(selected) }
        return
      end
      print_single_info(info)
    end

    private def print_single_info(info : Info)
      if print_templates(info, "video")
        return
      end
      listed = false
      if @options.bool?("listformats")
        print_formats(info)
        listed = true
      end
      if @options.bool?("listsubtitles")
        print_subtitles(info)
        listed = true
      end
      if @options.bool?("list_thumbnails")
        print_thumbnails(info)
        listed = true
      end
      return if listed

      if @options.bool?("dump_single_json") || @options.bool?("dumpjson") ||
         @options.bool?("forcejson") || @options.bool?("print_json")
        @output.puts(info.to_json)
      elsif @options.bool?("getid")
        @output.puts(info.id)
      elsif @options.bool?("gettitle")
        @output.puts(info.title)
      elsif @options.bool?("geturl")
        @output.puts(info.url)
      elsif @options.bool?("getthumbnail")
        @output.puts(info.string?("thumbnail") || "")
      elsif @options.bool?("getdescription")
        @output.puts(info.string?("description") || "")
      elsif @options.bool?("getduration")
        @output.puts(format_duration(info.float?("duration")))
      elsif @options.bool?("getfilename")
        @output.puts(prepare_filename(info))
      elsif @options.bool?("getformat")
        @output.puts(info.string?("format_id") || "")
      end
    end

    private def print_templates(info : Info, stage = "video") : Bool
      printable = printable_info(info)
      write_print_to_files(printable, stage)
      templates = @options.hash?("forceprint").try(&.[stage]?).try(&.as_a?)
      return false unless templates && !templates.empty?
      templates.each do |template|
        render_print_values(template.as_s, printable).each { |value| @output.puts(value) }
      end
      true
    end

    private def printable_info(info : Info) : Info
      printable = info.dup
      printable["filename"] = prepare_filename(info)
      printable
    end

    private def render_print_values(source : String, printable : Info) : Array(String)
      if source.includes?("%(") || source.includes?("%%")
        [output_template_renderer.render(source, printable, Math.max(1_i64, @num_downloads), sanitize: false)]
      else
        source.split(',').map do |field|
          output_template_renderer.render("%(#{field.strip})s", printable, Math.max(1_i64, @num_downloads), sanitize: false)
        end
      end
    end

    private def write_print_to_files(printable : Info, stage : String)
      entries = @options.hash?("print_to_file").try(&.[stage]?).try(&.as_a?)
      return unless entries && !entries.empty?
      entries.each do |entry|
        values = entry.as_h
        source = values["template"]?.try(&.as_s?) || next
        path_template = values["path"]?.try(&.as_s?) || next
        path = output_template_renderer.render(path_template, printable, Math.max(1_i64, @num_downloads))
        FileUtils.mkdir_p(Path.new(path).parent)
        File.open(path, "a") do |file|
          render_print_values(source, printable).each { |value| file.puts(value) }
        end
      end
    rescue error
      raise DownloadError.new("Unable to write print-to-file output: #{error.message}", cause: error)
    end

    private def print_formats(info : Info, io : IO? = nil)
      io ||= @output
      if info.string?("_type") == "playlist"
        info.array?("entries").try do |entries|
          entries.each { |entry| print_formats(Info.new(entry.as_h), io) }
        end
        return
      end
      io.puts("[info] Available formats for #{info.id}:")
      io.puts("ID  EXT   RESOLUTION  FILESIZE  NOTE")
      info.formats.each do |format_value|
        format = format_value.as_h
        id = format["format_id"]?.try(&.as_s?) || "-"
        ext = format["ext"]?.try(&.as_s?) || "-"
        width = format["width"]?.try(&.as_i64?)
        height = format["height"]?.try(&.as_i64?)
        resolution = width && height ? "#{width}x#{height}" : (height ? "#{height}p" : "audio only")
        filesize = format["filesize"]?.try(&.as_i64?)
        note = format["format"]?.try(&.as_s?) || format["format_note"]?.try(&.as_s?) || ""
        io.printf("%-3s %-5s %-11s %-9s %s\n", id, ext, resolution, human_filesize(filesize), note)
      end
    end

    private def print_subtitles(info : Info)
      print_subtitle_table(info.id, info.hash?("subtitles"), "subtitles")
      print_subtitle_table(info.id, info.hash?("automatic_captions"), "automatic captions")
    end

    private def print_subtitle_table(
      video_id : String,
      subtitles : Hash(String, JSON::Any)?,
      label : String,
    )
      unless subtitles && !subtitles.empty?
        @output.puts("#{video_id} has no #{label}")
        return
      end
      @output.puts("[info] Available #{label} for #{video_id}:")
      @output.puts("Language  Formats")
      subtitles.each do |language, formats|
        extensions = formats.as_a.compact_map do |format|
          values = format.as_h
          values["ext"]?.try(&.as_s?) ||
            values["url"]?.try(&.as_s?).try { |url| Manifest.extension(url) }
        end
        @output.puts("#{language}  #{extensions.uniq.join(", ")}")
      end
    end

    private def print_thumbnails(info : Info)
      thumbnails = thumbnail_entries(info)
      if thumbnails.empty?
        @output.puts("#{info.id} has no thumbnails")
        return
      end
      @output.puts("[info] Available thumbnails for #{info.id}:")
      @output.puts("ID  Width  Height  URL")
      thumbnails.each_with_index do |thumbnail, index|
        values = thumbnail.as_h
        id = values["id"]?.try(&.as_s?) || index.to_s
        width = values["width"]?.try(&.as_i64?).try(&.to_s) || "unknown"
        height = values["height"]?.try(&.as_i64?).try(&.to_s) || "unknown"
        url = values["url"]?.try(&.as_s?) || ""
        @output.puts("#{id}  #{width}  #{height}  #{url}")
      end
    end

    private def human_filesize(value : Int64?) : String
      return "-" unless value
      size = value.to_f64
      units = %w[B KiB MiB GiB]
      unit = 0
      while size >= 1024 && unit < units.size - 1
        size /= 1024
        unit += 1
      end
      unit == 0 ? "#{size.to_i}#{units[unit]}" : "%.1f%s" % {size, units[unit]}
    end

    private def format_duration(value : Float64?) : String
      return "" unless value
      total = value.round.to_i64
      hours = total // 3600
      minutes = (total % 3600) // 60
      seconds = total % 60
      hours > 0 ? "%d:%02d:%02d" % {hours, minutes, seconds} : "%d:%02d" % {minutes, seconds}
    end

    private def publish_postprocessor(status : String, processor : PostProcessor, info : Info)
      event = {
        "status"        => JSON::Any.new(status),
        "postprocessor" => JSON::Any.new(processor.key),
        "info_dict"     => JSON::Any.new(info.data),
      }
      @postprocessor_hooks.each(&.call(event))
    end

    private def write_info_json(info : Info, filename : String)
      extension = Path.new(filename).extension
      stem = extension.empty? ? filename : filename.rchop(extension)
      path = "#{stem}.info.json"
      File.write(path, info.to_pretty_json)
      info["infojson_filename"] = path
    rescue error
      raise DownloadError.new("Unable to write info JSON: #{error.message}", cause: error)
    end
  end
end
