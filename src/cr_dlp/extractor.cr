module CrDlp
  abstract class Extractor
    getter client : Client

    def initialize(@client : Client)
    end

    abstract def key : String
    abstract def name : String
    abstract def suitable?(url : String) : Bool
    abstract def extract(url : String) : Info

    protected def base_info(id : String, title : String, url : String) : Info
      info = Info.new
      info["id"] = id
      info["title"] = title
      info["url"] = url
      info["webpage_url"] = url
      info["original_url"] = url
      info["extractor"] = name
      info["extractor_key"] = key
      info
    end

    protected def open_websocket(
      url : String,
      headers = Hash(String, String).new,
    ) : Networking::WebSocketResponse
      @client.request_director.open_websocket(
        Networking::Request.new(url, headers: headers)
      )
    end
  end

  alias ExtractorFactory = Proc(Client, Extractor)

  record ExtractorRegistration,
    key : String,
    name : String,
    factory : ExtractorFactory

  class ExtractorRegistry
    getter registrations : Array(ExtractorRegistration)

    def initialize
      @registrations = [] of ExtractorRegistration
    end

    def register(key : String, name : String, &factory : Client -> Extractor)
      @registrations.reject! { |entry| entry.key == key }
      @registrations << ExtractorRegistration.new(key, name, factory)
    end

    def prepend(key : String, name : String, &factory : Client -> Extractor)
      @registrations.reject! { |entry| entry.key == key }
      @registrations.unshift(ExtractorRegistration.new(key, name, factory))
    end

    def build(key : String, client : Client) : Extractor
      registration = @registrations.find { |entry| entry.key == key } ||
                     raise ExtractorError.new("Unknown extractor #{key}")
      registration.factory.call(client)
    end

    def find(url : String, client : Client) : Extractor?
      @registrations.each do |registration|
        extractor = registration.factory.call(client)
        return extractor if extractor.suitable?(url)
      end
      nil
    end

    def keys : Array(String)
      @registrations.map(&.key)
    end
  end

  class FixtureExtractor < Extractor
    PREFIX = "cr-dlp:fixture:"

    def key : String
      "Fixture"
    end

    def name : String
      "fixture"
    end

    def suitable?(url : String) : Bool
      url.starts_with?(PREFIX)
    end

    def extract(url : String) : Info
      id = url[PREFIX.size..]
      raise ExtractorError.new("Fixture id cannot be empty", true) if id.empty?
      info = base_info(id, id, url)
      info["url"] = "fixture://#{id}"
      info["protocol"] = "fixture"
      info["ext"] = "txt"
      info["fixture_data"] = "fixture:#{id}\n"
      info
    end
  end

  class GenericExtractor < Extractor
    EXTENSIONS = %w[
      3gp aac avi flac flv gif jpeg jpg m4a m4v mkv mov mp3 mp4 mpeg mpg
      oga ogg opus png ts wav webm webp
    ]

    def key : String
      "Generic"
    end

    def name : String
      "generic"
    end

    def suitable?(url : String) : Bool
      scheme = URI.parse(url).scheme
      scheme == "http" || scheme == "https"
    rescue URI::Error
      false
    end

    def extract(url : String) : Info
      uri = URI.parse(url)
      basename = Path.new(uri.path).basename
      basename = uri.host || "download" if basename.empty? || basename == "/"
      extension = Path.new(basename).extension.lstrip('.').downcase
      return extract_hls(url, basename) if extension == "m3u8"
      return extract_dash(url, basename) if extension == "mpd"
      extension = "unknown_video" unless EXTENSIONS.includes?(extension)
      id = extension == "unknown_video" ? basename : basename.rchop(".#{extension}")
      info = base_info(id, id, url)
      info["ext"] = extension
      info["protocol"] = uri.scheme || "http"
      info
    end

    private def extract_hls(url : String, basename : String) : Info
      response = @client.request_director.send(Networking::Request.new(url))
      playlist = Manifest::Hls::Parser.parse(response.text, response.url)
      id = basename.rchop(".m3u8")
      info = base_info(id, id, url)
      info["ext"] = "mp4"
      info["protocol"] = "m3u8_native"
      info["manifest_url"] = response.url

      if playlist.media
        info["url"] = response.url
        info["formats"] = JSON::Any.new([media_format(response.url)])
        return info
      end

      audio_groups = playlist.renditions.compact_map do |rendition|
        rendition.group_id if rendition.media_type == "AUDIO" && rendition.url
      end.to_set
      formats = playlist.variants.map do |variant|
        JSON::Any.new(Manifest::Hls.variant_info(variant, response.url, audio_groups))
      end
      best = playlist.best_variant || raise ExtractorError.new("HLS master playlist has no variants")
      selected = Manifest::Hls.variant_info(best, response.url, audio_groups)
      info.merge!(selected)
      info["formats"] = JSON::Any.new(formats)
      subtitles = playlist.subtitles
      info["subtitles"] = JSON::Any.new(subtitles.transform_values { |entries| JSON::Any.new(entries.map { |entry| JSON::Any.new(entry) }) })
      info
    end

    private def media_format(url : String) : JSON::Any
      JSON::Any.new({
        "format_id" => JSON::Any.new("hls"),
        "url"       => JSON::Any.new(url),
        "ext"       => JSON::Any.new("mp4"),
        "protocol"  => JSON::Any.new("m3u8_native"),
      })
    end

    private def extract_dash(url : String, basename : String) : Info
      response = @client.request_director.send(Networking::Request.new(url))
      presentation = Manifest::Dash::Parser.parse(response.text, response.url)
      best = presentation.best_representation ||
             raise ExtractorError.new("DASH manifest has no downloadable formats")
      id = basename.rchop(".mpd")
      info = base_info(id, id, url)
      info.merge!(best.to_info(include_fragments: true))
      info.sidecar["dash_presentation"] = Manifest::Dash::PresentationSidecar.new(presentation)
      info["formats"] = JSON::Any.new(
        presentation.formats.map { |representation| JSON::Any.new(representation.to_info) }
      )
      subtitles = presentation.subtitles
      info["subtitles"] = JSON::Any.new(
        subtitles.transform_values { |entries| JSON::Any.new(entries.map { |entry| JSON::Any.new(entry) }) }
      )
      info
    end
  end
end
