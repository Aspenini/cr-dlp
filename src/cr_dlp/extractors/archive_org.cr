require "html"

module CrDlp
  class ArchiveOrgExtractor < Extractor
    MEDIA_EXTENSIONS = Set{
      "3gp", "aac", "aiff", "alac", "avi", "flac", "flv", "m4a", "m4v",
      "mka", "mkv", "mov", "mp2", "mp3", "mp4", "mpeg", "mpg", "oga",
      "ogg", "ogv", "opus", "shn", "ts", "wav", "webm", "wma", "wmv",
    }

    def key : String
      "ArchiveOrg"
    end

    def name : String
      "archive.org"
    end

    def suitable?(url : String) : Bool
      uri = URI.parse(url)
      return false unless uri.host.try { |host| host == "archive.org" || host == "www.archive.org" }
      uri.path.matches?(%r{\A/(?:details|embed)/[^/]+})
    rescue URI::Error
      false
    end

    def extract(url : String) : Info
      identifier, entry_id = match_id(url)
      metadata_response = @client.request_director.send(
        Networking::Request.new("https://archive.org/metadata/#{URI.encode_path_segment(identifier)}")
      )
      metadata = JSON.parse(metadata_response.text).as_h
      item_metadata = metadata["metadata"]?.try(&.as_h?) ||
                      raise ExtractorError.new("Archive.org response has no metadata")
      identifier = string_value(item_metadata["identifier"]?) || identifier

      playlist_response = @client.request_director.send(
        Networking::Request.new("https://archive.org/embed/#{URI.encode_path_segment(identifier)}")
      )
      playlist = parse_playlist(playlist_response.text)
      entries = build_entries(identifier, entry_id, playlist, metadata["files"]?.try(&.as_a?) || [] of JSON::Any)
      raise ExtractorError.new("Archive.org item has no downloadable media", true) if entries.empty?

      item = item_info(identifier, url, item_metadata)
      if entries.size == 1
        entry = entries.first
        if entry_id
          entry.merge!(shared_item_fields(item.data))
          entry["webpage_url"] = url
          entry["original_url"] = url
          return entry
        end
        entry.data.each do |key, value|
          next if key.in?("id", "title", "webpage_url", "original_url")
          item[key] = value
        end
        item["title"] = string_value(item_metadata["title"]?) || entry.title
        return item
      end

      item["_type"] = "playlist"
      item["entries"] = JSON::Any.new(entries.map { |entry| JSON::Any.new(entry.data) })
      item["playlist_count"] = entries.size
      item
    end

    private def match_id(url : String) : Tuple(String, String?)
      path = URI.decode(URI.parse(url).path)
      match = path.match(%r{\A/(?:details|embed)/([^/]+)(?:/(.+))?\z}) ||
              raise ExtractorError.new("Invalid Archive.org URL", true)
      {match[1], match[2]?}
    end

    private def parse_playlist(webpage : String) : Array(JSON::Any)
      match = webpage.match(/<play-av\b[^>]*\bplaylist=(['"])([\s\S]*?)\1/i) ||
              raise ExtractorError.new("Unable to find Archive.org player playlist")
      JSON.parse(HTML.unescape(match[2])).as_a
    rescue error : JSON::ParseException
      raise ExtractorError.new("Unable to parse Archive.org player playlist", cause: error)
    end

    private def build_entries(
      identifier : String,
      requested_entry : String?,
      playlist : Array(JSON::Any),
      files : Array(JSON::Any),
    ) : Array(Info)
      entries = Hash(String, Info).new
      playlist.each do |item|
        values = item.as_h
        original = string_value(values["orig"]?) || next
        next if requested_entry && original != requested_entry
        title = string_value(values["title"]?) || original
        entry = base_info("#{identifier}/#{original}", title, download_url(identifier, original))
        entry["webpage_url"] = "https://archive.org/details/#{identifier}/#{URI.encode_path(original)}"
        entry["original_url"] = entry.string?("webpage_url").not_nil!
        entry["display_id"] = original
        entry["track"] = title
        if duration = numeric_value(values["duration"]?)
          entry["duration"] = duration
        end
        entry["formats"] = JSON::Any.new([] of JSON::Any)
        entry["thumbnails"] = JSON::Any.new([] of JSON::Any)
        entries[original] = entry
      end

      files.each do |file_value|
        file = file_value.as_h
        name = string_value(file["name"]?) || next
        original = entries.has_key?(name) ? name : string_value(file["original"]?)
        next unless original
        entry = entries[original]?
        next unless entry
        format_name = string_value(file["format"]?)
        if format_name == "Thumbnail"
          append_thumbnail(entry, identifier, name, file)
          next
        end
        extension = Path.new(name).extension.lstrip('.').downcase
        next unless MEDIA_EXTENSIONS.includes?(extension)
        next if file["private"]?.try(&.as_bool?) == true
        append_format(entry, identifier, name, extension, file)
        apply_file_metadata(entry, file) if name == original
      end

      entries.values.select { |entry| !entry.formats.empty? }
    end

    private def append_format(
      entry : Info,
      identifier : String,
      name : String,
      extension : String,
      file : Hash(String, JSON::Any),
    )
      format = {
        "url"       => JSON::Any.new(download_url(identifier, name)),
        "format_id" => JSON::Any.new(entry.formats.size.to_s),
        "ext"       => JSON::Any.new(extension),
        "protocol"  => JSON::Any.new("https"),
      }
      if value = string_value(file["format"]?)
        format["format"] = JSON::Any.new(value)
      end
      if value = string_value(file["source"]?)
        format["format_note"] = JSON::Any.new(value)
      end
      format["source_preference"] = JSON::Any.new(file["source"]?.try(&.as_s?) == "original" ? 0_i64 : -1_i64)
      add_integer(format, "width", file["width"]?)
      add_integer(format, "height", file["height"]?)
      add_integer(format, "filesize", file["size"]?)
      if audio_extension?(extension)
        format["vcodec"] = JSON::Any.new("none")
        format["acodec"] = JSON::Any.new("unknown")
      else
        format["vcodec"] = JSON::Any.new("unknown")
        format["acodec"] = JSON::Any.new("unknown")
      end
      formats = entry.formats
      formats << JSON::Any.new(format)
      entry["formats"] = JSON::Any.new(formats)
    end

    private def append_thumbnail(
      entry : Info,
      identifier : String,
      name : String,
      file : Hash(String, JSON::Any),
    )
      thumbnail = {
        "id"  => JSON::Any.new(name),
        "url" => JSON::Any.new(download_url(identifier, name)),
      }
      add_integer(thumbnail, "width", file["width"]?)
      add_integer(thumbnail, "height", file["height"]?)
      add_integer(thumbnail, "filesize", file["size"]?)
      thumbnails = entry.array?("thumbnails") || [] of JSON::Any
      thumbnails << JSON::Any.new(thumbnail)
      entry["thumbnails"] = JSON::Any.new(thumbnails)
      entry["thumbnail"] = thumbnail["url"]
    end

    private def apply_file_metadata(entry : Info, file : Hash(String, JSON::Any))
      if value = string_value(file["title"]?) || string_value(file["name"]?)
        entry["title"] = value
      end
      entry["description"] = clean_text(file["description"]?) if file["description"]?
      if value = duration_value(file["length"]?)
        entry["duration"] = value
      end
      if value = string_value(file["album"]?)
        entry["album"] = value
      end
      if value = integer_value(file["track"]?)
        entry["track_number"] = value
      end
      if value = integer_value(file["year"]?)
        entry["release_year"] = value
      end
    end

    private def item_info(
      identifier : String,
      original_url : String,
      metadata : Hash(String, JSON::Any),
    ) : Info
      title = string_value(metadata["title"]?) || identifier
      info = base_info(identifier, title, original_url)
      info["webpage_url"] = "https://archive.org/details/#{identifier}"
      info["description"] = clean_text(metadata["description"]?) if metadata["description"]?
      if value = string_value(metadata["uploader"]?) || string_value(metadata["adder"]?)
        info["uploader"] = value
      end
      if value = string_value(metadata["licenseurl"]?)
        info["license"] = value
      end
      if value = string_value(metadata["venue"]?)
        info["location"] = value
      end
      if value = integer_value(metadata["year"]?)
        info["release_year"] = value
      end
      if value = timestamp_value(metadata["publicdate"]?) || timestamp_value(metadata["addeddate"]?)
        info["timestamp"] = value
      end
      creators = string_array(metadata["creator"]?)
      info["creators"] = JSON::Any.new(creators.map { |creator| JSON::Any.new(creator) }) unless creators.empty?
      info
    end

    private def shared_item_fields(data : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      data.reject { |key, _| key.in?("id", "title", "url", "formats", "display_id", "track", "duration", "thumbnail", "thumbnails") }
    end

    private def download_url(identifier : String, filename : String) : String
      "https://archive.org/download/#{URI.encode_path_segment(identifier)}/#{URI.encode_path(filename)}"
    end

    private def clean_text(value : JSON::Any?) : String
      source = if text = string_value(value)
                 text
               elsif array = value.try(&.as_a?)
                 array.compact_map { |item| string_value(item) }.join(" ")
               else
                 ""
               end
      HTML.unescape(source.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip)
    end

    private def string_array(value : JSON::Any?) : Array(String)
      return [] of String unless value
      if text = value.as_s?
        [text]
      elsif array = value.as_a?
        array.compact_map { |item| item.as_s? }
      else
        [] of String
      end
    end

    private def string_value(value : JSON::Any?) : String?
      return unless value
      value.as_s? || value.as_i64?.try(&.to_s) || value.as_f?.try(&.to_s)
    end

    private def numeric_value(value : JSON::Any?) : Float64?
      return unless value
      value.as_f? || value.as_i64?.try(&.to_f64) || value.as_s?.try(&.to_f64?)
    end

    private def integer_value(value : JSON::Any?) : Int64?
      return unless value
      value.as_i64? || value.as_s?.try(&.to_i64?)
    end

    private def duration_value(value : JSON::Any?) : Float64?
      text = string_value(value)
      return numeric_value(value) unless text && text.includes?(':')
      parts = text.split(':').map(&.to_f64)
      parts.reduce(0.0) { |total, part| total * 60 + part }
    end

    private def timestamp_value(value : JSON::Any?) : Int64?
      text = string_value(value) || return
      begin
        Time.parse_rfc3339(text).to_unix
      rescue Time::Format::Error
        begin
          Time.parse(text, "%F %T", Time::Location::UTC).to_unix
        rescue Time::Format::Error
          nil
        end
      end
    end

    private def add_integer(
      target : Hash(String, JSON::Any),
      key : String,
      value : JSON::Any?,
    )
      if integer = integer_value(value)
        target[key] = JSON::Any.new(integer)
      end
    end

    private def audio_extension?(extension : String) : Bool
      extension.in?("aac", "aiff", "alac", "flac", "m4a", "mka", "mp2", "mp3", "oga", "ogg", "opus", "shn", "wav", "wma")
    end
  end
end
