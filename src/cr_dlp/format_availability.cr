module CrDlp
  class FormatAvailabilityProbe
    @cache = Hash(String, Bool).new

    def initialize(@client : Client, @info : Info, @warning = true)
    end

    def working?(format : Hash(String, JSON::Any)) : Bool
      key = cache_key(format)
      return @cache[key] if @cache.has_key?(key)

      begin
        format_id = format["format_id"]?.try(&.as_s?) || "unknown"
        STDERR.puts("[info] Testing format #{format_id}")
        working = test_format(resolve_format(format))
        @cache[key] = working
        unless working
          message = "Unable to download format #{format_id}. Skipping..."
          prefix = @warning ? "WARNING: " : "[info] "
          STDERR.puts("#{prefix}#{message}")
        end
        working
      rescue error
        @cache[key] = false
        format_id = format["format_id"]?.try(&.as_s?) || "unknown"
        message = "Unable to download format #{format_id}. Skipping... (#{error.message})"
        prefix = @warning ? "WARNING: " : "[info] "
        STDERR.puts("#{prefix}#{message}")
        false
      end
    end

    private def test_format(format : Hash(String, JSON::Any)) : Bool
      protocol = format["protocol"]?.try(&.as_s?) ||
                 format["url"]?.try(&.as_s?).try { |url| URI.parse(url).scheme } ||
                 "http"
      return true if protocol == "fixture"
      return probe_hls(format) if protocol.starts_with?("m3u8")
      return probe_dash(format) if protocol == "http_dash_segments"

      url = format["url"]?.try(&.as_s?) ||
            raise DownloadError.new("Format is missing URL")
      @client.request_director.probe(
        Networking::Request.new(url, headers: request_headers(format)),
      )
      true
    end

    private def probe_hls(format : Hash(String, JSON::Any)) : Bool
      url = format["url"]?.try(&.as_s?) ||
            raise DownloadError.new("HLS format is missing URL")
      playlist = load_hls_media(url, request_headers(format))
      fragment = playlist.fragments.first? ||
                 raise DownloadError.new("HLS playlist contains no media fragments")
      headers = request_headers(format)
      headers["Range"] = fragment.byte_range.not_nil!.header if fragment.byte_range
      @client.request_director.probe(Networking::Request.new(fragment.url, headers: headers))
      true
    end

    private def load_hls_media(
      url : String,
      headers : Hash(String, String),
    ) : Manifest::Hls::Playlist
      response = @client.request_director.send(Networking::Request.new(url, headers: headers))
      playlist = Manifest::Hls::Parser.parse(response.text, response.url)
      return playlist if playlist.media
      variant = playlist.best_variant ||
                raise DownloadError.new("HLS master playlist has no variants")
      load_hls_media(variant.url, headers)
    end

    private def probe_dash(format : Hash(String, JSON::Any)) : Bool
      fragments = format["fragments"]?.try(&.as_a?) ||
                  raise DownloadError.new("DASH format has no fragments")
      fragment = fragments.first?.try(&.as_h) ||
                 raise DownloadError.new("DASH format has no fragments")
      url = fragment["url"]?.try(&.as_s?) ||
            raise DownloadError.new("DASH fragment is missing URL")
      headers = request_headers(format)
      if byte_range = fragment["range"]?.try(&.as_s?)
        headers["Range"] = "bytes=#{byte_range}"
      end
      @client.request_director.probe(Networking::Request.new(url, headers: headers))
      true
    end

    private def resolve_format(format : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      return format if format["fragments"]?
      format_id = format["format_id"]?.try(&.as_s?)
      return format unless format_id
      sidecar = @info.sidecar["dash_presentation"]?.as?(Manifest::Dash::PresentationSidecar)
      return format unless sidecar
      representation = sidecar.presentation.formats.find(&.id.==(format_id))
      representation ? representation.to_info(include_fragments: true) : format
    end

    private def request_headers(format : Hash(String, JSON::Any)) : Hash(String, String)
      headers = Hash(String, String).new
      @info.hash?("http_headers").try do |values|
        values.each { |name, value| headers[name] = value.as_s }
      end
      format["http_headers"]?.try(&.as_h?).try do |values|
        values.each { |name, value| headers[name] = value.as_s }
      end
      headers
    end

    private def cache_key(format : Hash(String, JSON::Any)) : String
      {
        format["format_id"]?.try(&.as_s?) || "",
        format["protocol"]?.try(&.as_s?) || "",
        format["url"]?.try(&.as_s?) || "",
      }.join("\0")
    end
  end
end
