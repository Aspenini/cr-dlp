module CrDlp
  module SubtitleSelector
    extend self

    def select(info : Info, options : ParsedOptions) : Hash(String, JSON::Any)
      available = Hash(String, Array(JSON::Any)).new
      normal_languages = [] of String

      normal_requested = options.bool?("writesubtitles") == true ||
                         (options.bool?("embedsubtitles") == true &&
                          options.bool?("writeautomaticsub") != true)
      if normal_requested
        append_tracks(available, info.hash?("subtitles"))
        normal_languages = available.keys
      end
      if options.bool?("writeautomaticsub")
        append_tracks(available, info.hash?("automatic_captions"), overwrite: false)
      end
      return Hash(String, JSON::Any).new if available.empty?

      languages = requested_languages(available.keys, normal_languages, options)
      preference = (options.string?("subtitlesformat") || "best").split('/')
      selected = Hash(String, JSON::Any).new
      languages.each do |language|
        formats = available[language]?
        next unless formats && !formats.empty?
        normalize_formats(formats)
        selected[language] = choose_format(formats, preference)
      end
      selected
    end

    private def append_tracks(
      available : Hash(String, Array(JSON::Any)),
      tracks : Hash(String, JSON::Any)?,
      overwrite = true,
    )
      return unless tracks
      tracks.each do |language, formats|
        next if !overwrite && available.has_key?(language)
        entries = formats.as_a?
        available[language] = entries.dup if entries && !entries.empty?
      end
    end

    private def requested_languages(
      all_languages : Array(String),
      normal_languages : Array(String),
      options : ParsedOptions,
    ) : Array(String)
      return all_languages.dup if options.bool?("allsubtitles")

      patterns = options.array?("subtitleslangs").try { |values| values.compact_map(&.as_s?) } || [] of String
      return languages_from_patterns(patterns, all_languages) unless patterns.empty?

      preferred = [] of String
      preferred << "en" if normal_languages.includes?("en")
      preferred.concat(normal_languages.select(&.starts_with?("en")))
      preferred << "en" if all_languages.includes?("en")
      preferred.concat(all_languages.select(&.starts_with?("en")))
      preferred.concat(normal_languages)
      preferred.concat(all_languages)
      preferred.uniq.first(1)
    end

    private def languages_from_patterns(
      patterns : Array(String),
      all_languages : Array(String),
    ) : Array(String)
      requested = [] of String
      patterns.each do |raw_pattern|
        discard = raw_pattern.starts_with?('-')
        pattern = discard ? raw_pattern.lchop('-') : raw_pattern
        matches = if pattern == "all"
                    all_languages
                  else
                    regex = Regex.new("\\A(?:#{pattern})\\z", Regex::Options::IGNORE_CASE)
                    all_languages.select { |language| regex.matches?(language) }
                  end
        if discard
          matches.each { |language| requested.delete(language) }
        else
          matches.each { |language| requested << language unless requested.includes?(language) }
        end
      end
      requested
    rescue error : Regex::Error | ArgumentError
      raise UsageError.new("Invalid subtitle language regular expression: #{error.message}", cause: error)
    end

    private def normalize_formats(formats : Array(JSON::Any))
      formats.each do |format_value|
        format = format_value.as_h
        next if format["ext"]?.try(&.as_s?)
        if url = format["url"]?.try(&.as_s?)
          format["ext"] = JSON::Any.new(Manifest.extension(url))
        else
          format["ext"] = JSON::Any.new("vtt")
        end
      end
    end

    private def choose_format(
      formats : Array(JSON::Any),
      preference : Array(String),
    ) : JSON::Any
      preference.each do |extension|
        return formats.last if extension == "best"
        match = formats.reverse_each.find do |format|
          format.as_h["ext"]?.try(&.as_s?) == extension
        end
        return match if match
      end
      formats.last
    end
  end
end
