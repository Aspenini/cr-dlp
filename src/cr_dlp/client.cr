require "file_utils"

module CrDlp
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
      auto_init = true,
    )
      @xattr_writer = xattr_writer || SystemXAttrWriter.new(@process_runner)
      @download_archive = @options.string?("download_archive").try { |path| DownloadArchive.new(path) }
      @cookie_jar = @options.string?("cookiefile").try { |path| CookieJar.load(path) }
      register_defaults if auto_init
    end

    def register_defaults
      @request_director.add(Networking::CrystalHttpHandler.new(
        timeout: (@options.float?("socket_timeout") || 20).seconds,
        verify_tls: !(@options.bool?("nocheckcertificate") == true),
        default_headers: default_http_headers,
        cookie_jar: @cookie_jar,
        proxy: @options.string?("proxy"),
      ))
      @request_director.add(Networking::CrystalWebSocketHandler.new(
        timeout: (@options.float?("socket_timeout") || 20).seconds,
        verify_tls: !(@options.bool?("nocheckcertificate") == true),
        default_headers: default_http_headers,
        cookie_jar: @cookie_jar,
        proxy: @options.string?("proxy"),
        client_certificate: @options.string?("client_certificate"),
        client_certificate_key: @options.string?("client_certificate_key"),
      ))
      @extractor_registry.register("Fixture", "fixture") { |client| FixtureExtractor.new(client) }
      @extractor_registry.register("ArchiveOrg", "archive.org") { |client| ArchiveOrgExtractor.new(client) }
      # Generic must remain the final fallback.
      @extractor_registry.register("Generic", "generic") { |client| GenericExtractor.new(client) }
      @downloader_registry.register(["fixture"]) { |client| FixtureDownloader.new(client) }
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
    end

    def hls_key(url : String, headers : Hash(String, String)) : Bytes
      @hls_keys[url] ||= @request_director.send(Networking::Request.new(url, headers: headers)).body
    end

    def extract_info(url : String, download = true) : Info
      extractor = extractor_for(url)
      info = extractor.extract(url)
      run_metadata_stage("pre_process", info)
      run_exec_stage("pre_process", info)
      run_metadata_stage("after_filter", info)
      run_sponsorblock(info)
      run_exec_stage("after_filter", info)
      return process_playlist(info, download) if info.string?("_type").in?("playlist", "multi_video")
      select_subtitles(info)
      selected = select_formats(info)
      selected.each { |selected_info| validate_info!(selected_info) }
      primary = selected.first
      if archived?(primary)
        primary.sidecar["archive_status"] = ArchiveStatus.new(true)
        STDERR.puts("[download] #{primary.id} has already been recorded in the archive")
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
    ensure
      @cookie_jar.try(&.save)
    end

    def download(urls : Enumerable(String)) : Int32
      errors = 0
      urls.each do |url|
        begin
          media_download = !simulate?
          info = extract_info(url, download: media_download)
          process_sidecars(info) if !media_download && sidecars_only?
          print_info(info)
          if archived?(info) && @options.bool?("break_on_existing")
            break
          end
        rescue error : Error
          errors += 1
          STDERR.puts("ERROR: #{error.message}")
          break unless @options.bool?("ignoreerrors")
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
      run_metadata_stage("before_dl", info)
      run_exec_stage("before_dl", info)
      if requested_formats = info.array?("requested_formats")
        download_requested_formats(info, filename, requested_formats)
        merger = @postprocessor_registry.build("FFmpegMerger", self)
        publish_postprocessor("started", merger, info)
        info = merger.run(info)
        publish_postprocessor("finished", merger, info)
      else
        downloader = @downloader_registry.build(info.protocol, self)
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
        return extractor if extractor.suitable?(url)
      end
      extractor = @extractor_registry.find(url, self) || raise UnsupportedUrlError.new(url)
      @extractor_instances[extractor.key] = extractor
      extractor
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
        run_sponsorblock(info)
        select_subtitles(info)
        selected = select_formats(info)
        selected.each { |selected_info| validate_info!(selected_info) }
        primary = selected.first
        if archived?(primary)
          primary.sidecar["archive_status"] = ArchiveStatus.new(true)
          processed << JSON::Any.new(primary.data)
          break if @options.bool?("break_on_existing")
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
        STDERR.puts("ERROR: #{error.message}")
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
          STDERR.puts("WARNING: #{message}")
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
          STDERR.puts("WARNING: Unable to download thumbnail #{identifier}: #{error.message}")
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
        @request_director.download(Networking::Request.new(url, headers: headers), output)
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

    private def sidecars_only? : Bool
      @options.bool?("skip_download") == true &&
        @options.bool?("simulate") != true &&
        (subtitle_requested? || thumbnail_requested?)
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
          STDERR.puts("WARNING: #{info.id}: #{message}")
          next
        end
        unless ffmpeg_available?
          STDERR.puts("WARNING: #{info.id}: #{message}. Install ffmpeg to fix this automatically")
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
        downloader = @downloader_registry.build(component.protocol, self)
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
      %w[
        dump_single_json forcejson listformats listsubtitles list_thumbnails gettitle geturl getthumbnail
        getdescription getduration getfilename getformat
      ].any? { |option| @options.bool?(option) }
    end

    private def print_info(info : Info)
      if info.string?("_type") == "playlist"
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
      if print_templates(info)
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

      if @options.bool?("dump_single_json") || @options.bool?("forcejson")
        STDOUT.puts(info.to_json)
      elsif @options.bool?("gettitle")
        STDOUT.puts(info.title)
      elsif @options.bool?("geturl")
        STDOUT.puts(info.url)
      elsif @options.bool?("getthumbnail")
        STDOUT.puts(info.string?("thumbnail") || "")
      elsif @options.bool?("getdescription")
        STDOUT.puts(info.string?("description") || "")
      elsif @options.bool?("getduration")
        STDOUT.puts(format_duration(info.float?("duration")))
      elsif @options.bool?("getfilename")
        STDOUT.puts(prepare_filename(info))
      elsif @options.bool?("getformat")
        STDOUT.puts(info.string?("format_id") || "")
      end
    end

    private def print_templates(info : Info, stage = "video") : Bool
      templates = @options.hash?("forceprint").try(&.[stage]?).try(&.as_a?)
      return false unless templates && !templates.empty?
      printable = info.dup
      printable["filename"] = prepare_filename(info)
      templates.each do |template|
        source = template.as_s
        if source.includes?("%(") || source.includes?("%%")
          STDOUT.puts(output_template_renderer.render(source, printable, Math.max(1_i64, @num_downloads), sanitize: false))
        else
          source.split(',').each do |field|
            STDOUT.puts(output_template_renderer.render("%(#{field.strip})s", printable, Math.max(1_i64, @num_downloads), sanitize: false))
          end
        end
      end
      true
    end

    private def print_formats(info : Info, io : IO = STDOUT)
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
        STDOUT.puts("#{video_id} has no #{label}")
        return
      end
      STDOUT.puts("[info] Available #{label} for #{video_id}:")
      STDOUT.puts("Language  Formats")
      subtitles.each do |language, formats|
        extensions = formats.as_a.compact_map do |format|
          values = format.as_h
          values["ext"]?.try(&.as_s?) ||
            values["url"]?.try(&.as_s?).try { |url| Manifest.extension(url) }
        end
        STDOUT.puts("#{language}  #{extensions.uniq.join(", ")}")
      end
    end

    private def print_thumbnails(info : Info)
      thumbnails = thumbnail_entries(info)
      if thumbnails.empty?
        STDOUT.puts("#{info.id} has no thumbnails")
        return
      end
      STDOUT.puts("[info] Available thumbnails for #{info.id}:")
      STDOUT.puts("ID  Width  Height  URL")
      thumbnails.each_with_index do |thumbnail, index|
        values = thumbnail.as_h
        id = values["id"]?.try(&.as_s?) || index.to_s
        width = values["width"]?.try(&.as_i64?).try(&.to_s) || "unknown"
        height = values["height"]?.try(&.as_i64?).try(&.to_s) || "unknown"
        url = values["url"]?.try(&.as_s?) || ""
        STDOUT.puts("#{id}  #{width}  #{height}  #{url}")
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
