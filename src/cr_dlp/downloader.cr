module CrDlp
  alias ProgressHook = Proc(Hash(String, JSON::Any), Nil)

  abstract class Downloader
    getter client : Client

    def initialize(@client : Client)
    end

    abstract def protocols : Array(String)
    abstract def download(info : Info, filename : String) : String

    protected def publish(status : String, info : Info, filename : String, downloaded : Int64? = nil)
      event = Hash(String, JSON::Any).new
      event["status"] = JSON::Any.new(status)
      event["filename"] = JSON::Any.new(filename)
      event["info_dict"] = JSON::Any.new(info.data)
      event["downloaded_bytes"] = JSON::Any.new(downloaded) if downloaded
      @client.publish_progress(event)
    end

    protected def atomic_write(filename : String, content : Bytes)
      part = "#{filename}.part"
      FileUtils.mkdir_p(Path.new(filename).parent)
      File.write(part, content)
      File.rename(part, filename)
    rescue error
      File.delete?(part) if part
      raise DownloadError.new("Unable to write #{filename}: #{error.message}", cause: error)
    end
  end

  alias DownloaderFactory = Proc(Client, Downloader)

  record DownloaderRegistration,
    protocols : Array(String),
    factory : DownloaderFactory

  class DownloaderRegistry
    getter registrations : Array(DownloaderRegistration)

    def initialize
      @registrations = [] of DownloaderRegistration
    end

    def register(protocols : Array(String), &factory : Client -> Downloader)
      @registrations << DownloaderRegistration.new(protocols, factory)
    end

    def build(protocol : String, client : Client) : Downloader
      registration = @registrations.find { |entry| entry.protocols.includes?(protocol) } ||
                     raise DownloadError.new("No downloader for protocol #{protocol}")
      registration.factory.call(client)
    end
  end

  class FixtureDownloader < Downloader
    def protocols : Array(String)
      ["fixture"]
    end

    def download(info : Info, filename : String) : String
      publish("downloading", info, filename, 0_i64)
      bytes = (info.string?("fixture_data") || "").to_slice
      atomic_write(filename, bytes)
      publish("finished", info, filename, bytes.size.to_i64)
      filename
    end
  end

  class HttpDownloader < Downloader
    def protocols : Array(String)
      ["http", "https"]
    end

    def download(info : Info, filename : String) : String
      if File.exists?(filename) && @client.options.bool?("overwrites") != true
        publish("finished", info, filename, File.size(filename))
        return filename
      end

      part = @client.options.bool?("nopart") ? filename : "#{filename}.part"
      FileUtils.mkdir_p(Path.new(filename).parent)
      File.delete?(part) if @client.options.bool?("continue_dl") == false
      attempts = retry_count + 1
      last_error = nil.as(Exception?)

      attempts.times do |attempt|
        offset = File.exists?(part) ? File.size(part) : 0_i64
        if (limit = test_limit) && offset >= limit
          last_error = nil
          break
        end
        headers = request_headers(info)
        if limit = test_limit
          headers["Range"] = "bytes=#{offset}-#{limit - 1}"
        elsif offset > 0
          headers["Range"] = "bytes=#{offset}-"
        end
        publish("downloading", info, filename, offset)
        begin
          mode = offset > 0 ? "ab" : "wb"
          File.open(part, mode) do |output|
            response = @client.request_director.download(
              Networking::Request.new(info.url, headers: headers),
              output,
              ->(received : Int64, total : Int64?) do
                publish("downloading", info, filename, offset + received)
              end,
            )
            if offset > 0 && response.status != 206
              output.close
              File.delete?(part)
              raise DownloadError.new("Server did not honor the resume request")
            end
          end
          last_error = nil
          break
        rescue error
          last_error = error
          sleep Math.min(2 ** attempt, 5).seconds if attempt + 1 < attempts
        end
      end
      raise DownloadError.new("Download failed after #{attempts} attempts", cause: last_error) if last_error

      unless part == filename
        File.delete?(filename)
        File.rename(part, filename)
      end
      publish("finished", info, filename, File.size(filename))
      filename
    rescue error : DownloadError
      raise error
    rescue error
      raise DownloadError.new("Unable to download #{info.url}: #{error.message}", cause: error)
    end

    private def request_headers(info : Info) : Hash(String, String)
      headers = Hash(String, String).new
      info.hash?("http_headers").try do |values|
        values.each { |key, value| headers[key] = value.as_s }
      end
      headers
    end

    private def retry_count : Int32
      value = @client.options["retries"]
      return 10 unless value
      if count = value.as_i64?
        Math.max(0, count.to_i)
      elsif text = value.as_s?
        text == "infinite" ? Int32::MAX : Math.max(0, text.to_i? || 10)
      else
        10
      end
    end

    private def test_limit : Int64?
      10_241_i64 if @client.options.bool?("test")
    end
  end

  record FragmentResult,
    index : Int32,
    bytes : Bytes?,
    error : Exception?

  class HlsDownloader < Downloader
    def protocols : Array(String)
      ["m3u8", "m3u8_native"]
    end

    def download(info : Info, filename : String) : String
      playlist = load_media_playlist(info.url, info)
      return download_live(info, filename, playlist) unless playlist.end_list

      fragments = playlist.fragments
      fragments = fragments.first(1) if @client.options.bool?("test")
      raise DownloadError.new("HLS playlist contains no media fragments") if fragments.empty?

      part = "#{filename}.part"
      state_path = "#{filename}.ytdl"
      start_index = prepare_resume(part, state_path, fragments.size)
      resume_size = File.exists?(part) ? File.size(part) : 0_i64
      publish_fragment(info, filename, start_index, fragments.size, resume_size)
      FileUtils.mkdir_p(Path.new(filename).parent)

      File.open(part, start_index > 0 ? "ab" : "wb") do |output|
        if concurrency > 1 && start_index == 0
          download_concurrently(fragments, info).each_with_index do |bytes, index|
            output.write(bytes)
            output.flush
            preserve_fragment(part, index, bytes)
            write_state(state_path, index + 1, fragments.size)
            publish_fragment(info, filename, index + 1, fragments.size, output.pos)
          end
        else
          fragments[start_index..].each_with_index do |fragment, offset|
            index = start_index + offset
            begin
              bytes = fetch_fragment(fragment, info)
              output.write(bytes)
              output.flush
              preserve_fragment(part, index, bytes)
              write_state(state_path, index + 1, fragments.size)
              publish_fragment(info, filename, index + 1, fragments.size, output.pos)
            rescue error
              if skip_unavailable?
                STDERR.puts("WARNING: Skipping fragment #{index + 1}: #{error.message}")
                next
              end
              raise error
            end
          end
        end
      end

      File.rename(part, filename)
      File.delete?(state_path)
      publish("finished", info, filename, File.size(filename))
      filename
    rescue error : DownloadError
      raise error
    rescue error
      raise DownloadError.new("Unable to download HLS stream: #{error.message}", cause: error)
    end

    private def load_media_playlist(url : String, info : Info) : Manifest::Hls::Playlist
      response = @client.request_director.send(
        Networking::Request.new(url, headers: request_headers(info))
      )
      playlist = Manifest::Hls::Parser.parse(response.text, response.url)
      if playlist.media
        playlist
      elsif variant = playlist.best_variant
        load_media_playlist(variant.url, info)
      else
        raise DownloadError.new("HLS master playlist has no variants")
      end
    end

    private def download_live(
      info : Info,
      filename : String,
      initial_playlist : Manifest::Hls::Playlist,
    ) : String
      part = "#{filename}.part"
      state_path = "#{filename}.ytdl"
      seen = prepare_live_resume(part, state_path)
      FileUtils.mkdir_p(Path.new(filename).parent)
      playlist = initial_playlist
      downloaded_fragments = seen.size
      publish_fragment(info, filename, downloaded_fragments, downloaded_fragments, File.exists?(part) ? File.size(part) : 0_i64)

      File.open(part, seen.empty? ? "wb" : "ab") do |output|
        loop do
          pending = playlist.fragments.reject { |fragment| seen.includes?(hls_fragment_key(fragment)) }
          pending = pending.first(1) if @client.options.bool?("test")
          pending.each do |fragment|
            key = hls_fragment_key(fragment)
            begin
              bytes = fetch_fragment(fragment, info)
              output.write(bytes)
              output.flush
              preserve_fragment(part, downloaded_fragments, bytes)
            rescue error
              raise error unless skip_unavailable?
              STDERR.puts("WARNING: Skipping fragment #{downloaded_fragments + 1}: #{error.message}")
            end
            seen << key
            downloaded_fragments += 1
            write_live_state(state_path, seen)
            publish_fragment(
              info,
              filename,
              downloaded_fragments,
              downloaded_fragments + playlist.fragments.count { |fragment| !seen.includes?(hls_fragment_key(fragment)) },
              output.pos,
            )
          end

          break if @client.options.bool?("test") || playlist.end_list
          sleep live_refresh_interval(playlist.target_duration)
          playlist = load_media_playlist(playlist.url, info)
        end
      end

      File.delete?(filename)
      File.rename(part, filename)
      File.delete?(state_path)
      publish("finished", info, filename, File.size(filename))
      filename
    end

    private def hls_fragment_key(fragment : Manifest::Hls::Fragment) : String
      range = fragment.byte_range.try { |value| "#{value.start}-#{value.finish}" } || ""
      if fragment.initialization
        "init:#{fragment.url}:#{range}"
      else
        "media:#{fragment.media_sequence}:#{fragment.url}:#{range}"
      end
    end

    private def prepare_live_resume(part : String, state_path : String) : Set(String)
      unless continuedl? && File.exists?(part) && File.exists?(state_path)
        File.delete?(part)
        File.delete?(state_path)
        return Set(String).new
      end
      state = JSON.parse(File.read(state_path)).as_h
      keys = state["fragment_keys"]?.try(&.as_a?) || return Set(String).new
      keys.compact_map(&.as_s?).to_set
    rescue JSON::ParseException
      File.delete?(part)
      File.delete?(state_path)
      Set(String).new
    end

    private def write_live_state(path : String, seen : Set(String))
      File.write(path, {"fragment_keys" => seen.to_a}.to_json)
    end

    private def live_refresh_interval(target_duration : Float64?) : Time::Span
      Math.max(0.05, Math.min(target_duration || 1.0, 5.0)).seconds
    end

    private def fetch_fragment(fragment : Manifest::Hls::Fragment, info : Info) : Bytes
      attempts = fragment_retries + 1
      last_error = nil.as(Exception?)
      attempts.times do |attempt|
        begin
          headers = request_headers(info)
          if range = fragment.byte_range
            headers["Range"] = range.header
          end
          response = @client.request_director.send(Networking::Request.new(fragment.url, headers: headers))
          bytes = response.body
          if encryption = fragment.encryption
            bytes = decrypt(bytes, encryption, fragment.media_sequence, info)
          end
          return bytes
        rescue error
          last_error = error
          sleep retry_delay(attempt) if attempt + 1 < attempts
        end
      end
      raise DownloadError.new("Fragment #{fragment.url} failed after #{attempts} attempts", cause: last_error)
    end

    private def download_concurrently(
      fragments : Array(Manifest::Hls::Fragment),
      info : Info,
    ) : Array(Bytes)
      jobs = Channel(Tuple(Int32, Manifest::Hls::Fragment)).new
      results = Channel(FragmentResult).new
      worker_count = Math.min(concurrency, fragments.size)

      worker_count.times do
        spawn do
          while job = jobs.receive?
            index, fragment = job
            begin
              results.send(FragmentResult.new(index, fetch_fragment(fragment, info), nil))
            rescue error
              results.send(FragmentResult.new(index, nil, error))
            end
          end
        end
      end
      spawn do
        fragments.each_with_index { |fragment, index| jobs.send({index, fragment}) }
        jobs.close
      end

      ordered = Array(Bytes?).new(fragments.size, nil)
      fragments.size.times do
        result = results.receive
        if error = result.error
          if skip_unavailable?
            STDERR.puts("WARNING: Skipping fragment #{result.index + 1}: #{error.message}")
            ordered[result.index] = Bytes.empty
          else
            raise error
          end
        else
          ordered[result.index] = result.bytes
        end
      end
      ordered.map(&.not_nil!)
    end

    private def decrypt(
      bytes : Bytes,
      encryption : Manifest::Hls::Encryption,
      media_sequence : Int64,
      info : Info,
    ) : Bytes
      unless encryption.method == "AES-128"
        raise DownloadError.new("Unsupported HLS encryption method #{encryption.method}")
      end
      key_url = encryption.key_url || raise DownloadError.new("HLS AES-128 key URI is missing")
      key = @client.hls_key(key_url, request_headers(info))
      raise DownloadError.new("Invalid HLS AES-128 key length #{key.size}") unless key.size == 16
      unless bytes.size % AES::BLOCK_SIZE == 0
        raise DownloadError.new("Invalid HLS AES-128 fragment length #{bytes.size}")
      end
      iv = encryption.iv || sequence_iv(media_sequence)
      AES.unpad_pkcs7(AES.aes_cbc_decrypt_bytes(bytes, key, iv), validate: true)
    rescue error : CryptoError
      raise DownloadError.new("Unable to decrypt HLS AES-128 fragment", cause: error)
    end

    private def sequence_iv(sequence : Int64) : Bytes
      Bytes.new(16).tap do |iv|
        8.times { |index| iv[15 - index] = ((sequence >> (index * 8)) & 0xff).to_u8 }
      end
    end

    private def prepare_resume(part : String, state_path : String, fragment_count : Int32) : Int32
      unless continuedl? && File.exists?(part) && File.exists?(state_path)
        File.delete?(part)
        File.delete?(state_path)
        return 0
      end
      state = JSON.parse(File.read(state_path)).as_h
      count = state["fragment_count"]?.try(&.as_i) || 0
      index = state["fragment_index"]?.try(&.as_i) || 0
      return index if count == fragment_count && 0 <= index <= fragment_count
      File.delete?(part)
      File.delete?(state_path)
      0
    rescue JSON::ParseException
      File.delete?(part)
      File.delete?(state_path)
      0
    end

    private def write_state(path : String, index : Int32, count : Int32)
      File.write(path, {
        "fragment_index" => index,
        "fragment_count" => count,
      }.to_json)
    end

    private def preserve_fragment(part : String, index : Int32, bytes : Bytes)
      return unless @client.options.bool?("keep_fragments")
      File.write("#{part}-Frag#{index + 1}", bytes)
    end

    private def publish_fragment(
      info : Info,
      filename : String,
      index : Int32,
      count : Int32,
      downloaded : Int64,
    )
      event = {
        "status"           => JSON::Any.new("downloading"),
        "filename"         => JSON::Any.new(filename),
        "info_dict"        => JSON::Any.new(info.data),
        "downloaded_bytes" => JSON::Any.new(downloaded),
        "fragment_index"   => JSON::Any.new(index.to_i64),
        "fragment_count"   => JSON::Any.new(count.to_i64),
      }
      @client.publish_progress(event)
    end

    private def request_headers(info : Info) : Hash(String, String)
      headers = Hash(String, String).new
      info.hash?("http_headers").try do |values|
        values.each { |key, value| headers[key] = value.as_s }
      end
      headers
    end

    private def concurrency : Int32
      Math.max(1, (@client.options.int?("concurrent_fragment_downloads") || 1).to_i)
    end

    private def fragment_retries : Int32
      Math.max(0, (@client.options.int?("fragment_retries") || 10).to_i)
    end

    private def retry_delay(attempt : Int32) : Time::Span
      Math.min(2 ** attempt, 5).seconds
    end

    private def continuedl? : Bool
      @client.options.bool?("continue_dl") != false
    end

    private def skip_unavailable? : Bool
      @client.options.bool?("skip_unavailable_fragments") != false
    end
  end

  class DashDownloader < Downloader
    def protocols : Array(String)
      ["http_dash_segments"]
    end

    def download(info : Info, filename : String) : String
      fragments = info.array?("fragments") || raise DownloadError.new("DASH format has no fragments")
      if info.bool?("is_live") == true
        return download_live(info, filename, fragments)
      end
      fragments = fragments.first(1) if @client.options.bool?("test")
      raise DownloadError.new("DASH format has no fragments") if fragments.empty?

      part = "#{filename}.part"
      state_path = "#{filename}.ytdl"
      start_index = prepare_resume(part, state_path, fragments.size)
      FileUtils.mkdir_p(Path.new(filename).parent)
      publish_fragment(info, filename, start_index, fragments.size, File.exists?(part) ? File.size(part) : 0_i64)

      File.open(part, start_index > 0 ? "ab" : "wb") do |output|
        fragments[start_index..].each_with_index do |fragment, offset|
          index = start_index + offset
          begin
            bytes = fetch_fragment(fragment.as_h, info)
            output.write(bytes)
            output.flush
            preserve_fragment(part, index, bytes)
            write_state(state_path, index + 1, fragments.size)
            publish_fragment(info, filename, index + 1, fragments.size, output.pos)
          rescue error
            if skip_unavailable?
              STDERR.puts("WARNING: Skipping fragment #{index + 1}: #{error.message}")
              next
            end
            raise error
          end
        end
      end

      File.rename(part, filename)
      File.delete?(state_path)
      publish("finished", info, filename, File.size(filename))
      filename
    rescue error : DownloadError
      raise error
    rescue error
      raise DownloadError.new("Unable to download DASH stream: #{error.message}", cause: error)
    end

    private def fetch_fragment(fragment : Hash(String, JSON::Any), info : Info) : Bytes
      url = fragment["url"]?.try(&.as_s?) || raise DownloadError.new("DASH fragment is missing URL")
      attempts = fragment_retries + 1
      last_error = nil.as(Exception?)
      attempts.times do |attempt|
        begin
          headers = request_headers(info)
          if byte_range = fragment["range"]?.try(&.as_s?)
            headers["Range"] = "bytes=#{byte_range}"
          end
          return @client.request_director.send(Networking::Request.new(url, headers: headers)).body
        rescue error
          last_error = error
          sleep Math.min(2 ** attempt, 5).seconds if attempt + 1 < attempts
        end
      end
      raise DownloadError.new("DASH fragment #{url} failed after #{attempts} attempts", cause: last_error)
    end

    private def download_live(
      info : Info,
      filename : String,
      initial_fragments : Array(JSON::Any),
    ) : String
      sidecar = info.sidecar["dash_presentation"]?.as?(Manifest::Dash::PresentationSidecar) ||
                raise DownloadError.new("Dynamic DASH format is missing presentation state")
      format_id = info.string?("format_id") ||
                  raise DownloadError.new("Dynamic DASH format is missing format ID")
      manifest_url = info.string?("manifest_url") || info.url
      part = "#{filename}.part"
      state_path = "#{filename}.ytdl"
      seen = prepare_live_resume(part, state_path)
      FileUtils.mkdir_p(Path.new(filename).parent)
      presentation = sidecar.presentation
      fragments = initial_fragments
      downloaded_fragments = seen.size
      publish_fragment(info, filename, downloaded_fragments, fragments.size, File.exists?(part) ? File.size(part) : 0_i64)

      File.open(part, seen.empty? ? "wb" : "ab") do |output|
        loop do
          pending = fragments.reject { |fragment| seen.includes?(dash_fragment_key(fragment.as_h)) }
          pending = pending.first(1) if @client.options.bool?("test")
          pending.each do |fragment|
            values = fragment.as_h
            key = dash_fragment_key(values)
            begin
              bytes = fetch_fragment(values, info)
              output.write(bytes)
              output.flush
              preserve_fragment(part, downloaded_fragments, bytes)
            rescue error
              raise error unless skip_unavailable?
              STDERR.puts("WARNING: Skipping fragment #{downloaded_fragments + 1}: #{error.message}")
            end
            seen << key
            downloaded_fragments += 1
            write_live_state(state_path, seen)
            publish_fragment(info, filename, downloaded_fragments, Math.max(downloaded_fragments, fragments.size), output.pos)
          end

          break if @client.options.bool?("test") || !presentation.dynamic
          sleep live_refresh_interval(presentation.minimum_update_period)
          response = @client.request_director.send(
            Networking::Request.new(manifest_url, headers: request_headers(info))
          )
          manifest_url = response.url
          presentation = Manifest::Dash::Parser.parse(response.text, response.url)
          representation = presentation.formats.find(&.id.==(format_id)) ||
                           raise DownloadError.new("Dynamic DASH format #{format_id} disappeared from the manifest")
          fragments = representation.fragments.map(&.to_info)
        end
      end

      File.delete?(filename)
      File.rename(part, filename)
      File.delete?(state_path)
      publish("finished", info, filename, File.size(filename))
      filename
    end

    private def dash_fragment_key(fragment : Hash(String, JSON::Any)) : String
      "#{fragment["url"]?.try(&.as_s?) || ""}:#{fragment["range"]?.try(&.as_s?) || ""}"
    end

    private def prepare_live_resume(part : String, state_path : String) : Set(String)
      unless @client.options.bool?("continue_dl") != false && File.exists?(part) && File.exists?(state_path)
        File.delete?(part)
        File.delete?(state_path)
        return Set(String).new
      end
      state = JSON.parse(File.read(state_path)).as_h
      keys = state["fragment_keys"]?.try(&.as_a?) || return Set(String).new
      keys.compact_map(&.as_s?).to_set
    rescue JSON::ParseException
      File.delete?(part)
      File.delete?(state_path)
      Set(String).new
    end

    private def write_live_state(path : String, seen : Set(String))
      File.write(path, {"fragment_keys" => seen.to_a}.to_json)
    end

    private def live_refresh_interval(minimum_update_period : Float64?) : Time::Span
      Math.max(0.05, Math.min(minimum_update_period || 1.0, 5.0)).seconds
    end

    private def prepare_resume(part : String, state_path : String, fragment_count : Int32) : Int32
      unless @client.options.bool?("continue_dl") != false && File.exists?(part) && File.exists?(state_path)
        File.delete?(part)
        File.delete?(state_path)
        return 0
      end
      state = JSON.parse(File.read(state_path)).as_h
      count = state["fragment_count"]?.try(&.as_i) || 0
      index = state["fragment_index"]?.try(&.as_i) || 0
      return index if count == fragment_count && 0 <= index <= fragment_count
      File.delete?(part)
      File.delete?(state_path)
      0
    rescue JSON::ParseException
      File.delete?(part)
      File.delete?(state_path)
      0
    end

    private def write_state(path : String, index : Int32, count : Int32)
      File.write(path, {"fragment_index" => index, "fragment_count" => count}.to_json)
    end

    private def preserve_fragment(part : String, index : Int32, bytes : Bytes)
      return unless @client.options.bool?("keep_fragments")
      File.write("#{part}-Frag#{index + 1}", bytes)
    end

    private def publish_fragment(
      info : Info,
      filename : String,
      index : Int32,
      count : Int32,
      downloaded : Int64,
    )
      @client.publish_progress({
        "status"           => JSON::Any.new("downloading"),
        "filename"         => JSON::Any.new(filename),
        "info_dict"        => JSON::Any.new(info.data),
        "downloaded_bytes" => JSON::Any.new(downloaded),
        "fragment_index"   => JSON::Any.new(index.to_i64),
        "fragment_count"   => JSON::Any.new(count.to_i64),
      })
    end

    private def request_headers(info : Info) : Hash(String, String)
      headers = Hash(String, String).new
      info.hash?("http_headers").try do |values|
        values.each { |key, value| headers[key] = value.as_s }
      end
      headers
    end

    private def fragment_retries : Int32
      Math.max(0, (@client.options.int?("fragment_retries") || 10).to_i)
    end

    private def skip_unavailable? : Bool
      @client.options.bool?("skip_unavailable_fragments") != false
    end
  end

  class WebSocketFragmentDownloader < Downloader
    def protocols : Array(String)
      ["websocket_frag", "web_socket_fragment"]
    end

    def download(info : Info, filename : String) : String
      if File.exists?(filename) && @client.options.bool?("overwrites") != true
        publish("finished", info, filename, File.size(filename))
        return filename
      end

      ffmpeg = ffmpeg_path
      unless @client.process_runner.executable_available?(ffmpeg)
        raise DownloadError.new("ffmpeg is required to download WebSocket fragments")
      end

      part = temporary_filename(filename)
      FileUtils.mkdir_p(Path.new(filename).parent)
      File.delete?(part)
      response = @client.request_director.open_websocket(
        Networking::Request.new(info.url, headers: request_headers(info))
      )
      downloaded = 0_i64
      publish("downloading", info, filename, downloaded)

      result = begin
        @client.process_runner.run_with_input(
          ffmpeg,
          ffmpeg_arguments(info, part),
        ) do |input|
          downloaded = stream_messages(response, input, info, filename)
        end
      ensure
        response.close
      end

      unless result.success?
        detail = result.error.strip
        detail = result.output.strip if detail.empty?
        raise DownloadError.new(
          "ffmpeg WebSocket download failed#{detail.empty? ? "" : ": #{detail}"}"
        )
      end
      unless File.exists?(part)
        raise DownloadError.new("ffmpeg completed without creating WebSocket output")
      end

      File.delete?(filename)
      File.rename(part, filename)
      publish("finished", info, filename, File.size(filename))
      filename
    rescue error : DownloadError
      raise error
    rescue error
      raise DownloadError.new("Unable to download WebSocket stream: #{error.message}", cause: error)
    end

    private def stream_messages(
      response : Networking::WebSocketResponse,
      input : IO,
      info : Info,
      filename : String,
    ) : Int64
      downloaded = 0_i64
      loop do
        message = receive_message(response)
        break unless message
        size = write_message(input, message)
        input.flush
        downloaded += size
        publish("downloading", info, filename, downloaded)
        break if @client.options.bool?("test")
      end
      downloaded
    end

    private def write_message(input : IO, message : String) : Int32
      input.write(message.to_slice)
      message.bytesize
    end

    private def write_message(input : IO, message : Bytes) : Int32
      input.write(message)
      message.size
    end

    private def receive_message(response : Networking::WebSocketResponse) : String | Bytes | Nil
      response.recv
    rescue error : RequestError
      return nil if response.closed?
      raise error
    end

    private def request_headers(info : Info) : Hash(String, String)
      headers = Hash(String, String).new
      info.hash?("http_headers").try do |values|
        values.each { |key, value| headers[key] = value.as_s }
      end
      headers
    end

    private def ffmpeg_arguments(info : Info, output : String) : Array(String)
      arguments = %w[-y -loglevel repeat+info -i pipe:0 -c copy]
      output_format(info.ext).try do |format|
        arguments.concat(["-f", format])
      end
      arguments << output
      arguments
    end

    private def output_format(extension : String) : String?
      case extension.downcase
      when "mp4", "m4v"         then "mp4"
      when "m4a"                then "ipod"
      when "mkv"                then "matroska"
      when "webm"               then "webm"
      when "ts", "m2ts"         then "mpegts"
      when "flv"                then "flv"
      when "mp3"                then "mp3"
      when "ogg", "oga", "opus" then "ogg"
      end
    end

    private def temporary_filename(filename : String) : String
      extension = Path.new(filename).extension
      return "#{filename}.part" if extension.empty?
      "#{filename.rchop(extension)}.part#{extension}"
    end

    private def ffmpeg_path : String
      location = @client.options.string?("ffmpeg_location")
      return "ffmpeg" unless location
      executable = {{ flag?(:win32) ? "ffmpeg.exe" : "ffmpeg" }}
      File.directory?(location) ? File.join(location, executable) : location
    end
  end
end
