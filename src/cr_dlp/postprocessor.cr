require "base64"
require "digest/sha256"

module CrDlp
  class MergerInputs < SidecarValue
    getter paths : Array(String)

    def initialize(@paths : Array(String))
    end
  end

  class MovePlan < SidecarValue
    getter temporary_root : String
    getter final_root : String
    getter final_path : String

    def initialize(@temporary_root : String, @final_root : String, @final_path : String)
    end
  end

  class ExtraSidecarFiles < SidecarValue
    getter paths : Array(String)

    def initialize(@paths = [] of String)
    end

    def add(path : String)
      @paths << path unless @paths.includes?(path)
    end
  end

  abstract class PostProcessor
    getter client : Client

    def initialize(@client : Client)
    end

    abstract def key : String
    abstract def run(info : Info) : Info
  end

  alias PostProcessorFactory = Proc(Client, PostProcessor)

  record PostProcessorRegistration,
    key : String,
    factory : PostProcessorFactory

  class PostProcessorRegistry
    getter registrations : Array(PostProcessorRegistration)

    def initialize
      @registrations = [] of PostProcessorRegistration
    end

    def register(key : String, &factory : Client -> PostProcessor)
      @registrations.reject! { |entry| entry.key == key }
      @registrations << PostProcessorRegistration.new(key, factory)
    end

    def build(key : String, client : Client) : PostProcessor
      registration = @registrations.find { |entry| entry.key == key } ||
                     raise PostProcessingError.new("Unknown postprocessor #{key}")
      registration.factory.call(client)
    end
  end

  class MetadataPostProcessor < PostProcessor
    def key : String
      "Metadata"
    end

    def run(info : Info) : Info
      if !info.string?("filepath") && (filename = info.string?("_filename"))
        info["filepath"] = filename
      end
      info
    end
  end

  class MetadataParserPostProcessor < PostProcessor
    def initialize(client : Client, @actions : Array(JSON::Any))
      super(client)
    end

    def key : String
      "MetadataParser"
    end

    def run(info : Info) : Info
      @actions.each do |action|
        values = action.as_h
        case values["type"].as_s
        when "interpret"
          interpret(info, values["input"].as_s, values["output"].as_s)
        when "replace"
          replace(
            info,
            values["field"].as_s,
            values["search"].as_s,
            values["replacement"].as_s,
          )
        else
          raise PostProcessingError.new("Unknown metadata parser action")
        end
      end
      info
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to parse metadata: #{error.message}", cause: error)
    end

    def self.field_to_template(value : String) : String
      value.matches?(/\A[a-zA-Z_]+\z/) ? "%(#{value})s" : value
    end

    def self.format_to_regex(value : String) : String
      return "(?<#{value}>.+)" if value.matches?(/\A\w+\z/)
      return value unless value.matches?(/%\(\w+\)s/)

      String.build do |output|
        position = 0
        value.scan(/%\((\w+)\)s/) do |match|
          output << Regex.escape(value[position...match.begin(0)])
          output << "(?<" << match[1] << ">.+)"
          position = match.end(0)
        end
        output << Regex.escape(value[position..]) if position < value.size
      end
    end

    private def interpret(info : Info, input : String, output : String)
      template = self.class.field_to_template(input)
      source = OutputTemplate.new(na_placeholder: "").render(template, info, sanitize: false)
      expression = Regex.new(self.class.format_to_regex(output), Regex::Options::MULTILINE)
      match = expression.match(source)
      unless match
        @client.info_log("[MetadataParser] Could not interpret #{input.inspect} as #{output.inspect}")
        return
      end
      match.named_captures.each do |name, value|
        info[name] = value if value
      end
    end

    private def replace(info : Info, field : String, search : String, replacement : String)
      value = info.string?(field)
      unless value
        if info[field]?
          @client.warning("Cannot replace in non-string metadata field #{field}")
        else
          @client.info_log("[MetadataParser] Video does not have a #{field}")
        end
        return
      end
      info[field] = value.gsub(Regex.new(search), replacement)
    end
  end

  class SponsorBlockPostProcessor < PostProcessor
    CATEGORIES = {
      "sponsor"        => "Sponsor",
      "intro"          => "Intermission/Intro Animation",
      "outro"          => "Endcards/Credits",
      "selfpromo"      => "Unpaid/Self Promotion",
      "preview"        => "Preview/Recap",
      "filler"         => "Filler Tangent",
      "interaction"    => "Interaction Reminder",
      "music_offtopic" => "Non-Music Section",
      "hook"           => "Hook/Greetings",
      "poi_highlight"  => "Highlight",
      "chapter"        => "Chapter",
    }
    POI_CATEGORIES = %w[poi_highlight]

    def key : String
      "SponsorBlock"
    end

    def run(info : Info) : Info
      unless info.string?("extractor_key") == "Youtube"
        @client.info_log("[SponsorBlock] SponsorBlock is not supported for #{info.string?("extractor_key") || "unknown"}")
        return info
      end

      segments = fetch_segments(info.id, sponsorblock_categories)
      duration = info.float?("duration")
      chapters = [] of JSON::Any
      rejected = 0
      segments.each do |value|
        segment = value.as_h
        bounds = segment["segment"]?.try(&.as_a?)
        category = segment["category"]?.try(&.as_s?)
        unless bounds && bounds.size >= 2 && category && CATEGORIES.has_key?(category)
          rejected += 1
          next
        end
        start_time = json_number(bounds[0])
        end_time = json_number(bounds[1])
        unless start_time && end_time && valid_duration?(segment, start_time, end_time, duration)
          rejected += 1
          next
        end
        next if start_time == 0 && end_time == 0
        start_time = 0.0 if start_time <= 1
        end_time += 1 if POI_CATEGORIES.includes?(category)
        end_time = duration if duration && duration - end_time <= 1
        end_time = Math.min(end_time, duration) if duration
        next if end_time <= start_time

        title = if category == "chapter"
                  segment["description"]?.try(&.as_s?) || CATEGORIES[category]
                else
                  CATEGORIES[category]
                end
        chapters << JSON::Any.new({
          "start_time"  => JSON::Any.new(start_time),
          "end_time"    => JSON::Any.new(end_time),
          "category"    => JSON::Any.new(category),
          "title"       => JSON::Any.new(title),
          "type"        => segment["actionType"]? || JSON::Any.new("skip"),
          "_categories" => JSON::Any.new([
            JSON::Any.new([
              JSON::Any.new(category),
              JSON::Any.new(start_time),
              JSON::Any.new(end_time),
              JSON::Any.new(title),
            ]),
          ]),
        })
      end
      @client.warning("Some SponsorBlock segments have incompatible durations") if rejected > 0
      info["sponsorblock_chapters"] = JSON::Any.new(chapters)
      info
    rescue error : HttpError
      if error.status == 404
        info["sponsorblock_chapters"] = JSON::Any.new([] of JSON::Any)
        return info
      end
      raise PostProcessingError.new("Unable to fetch SponsorBlock segments: #{error.message}", cause: error)
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to fetch SponsorBlock segments: #{error.message}", cause: error)
    end

    private def sponsorblock_categories : Array(String)
      marked = @client.options.array?("sponsorblock_mark").try(&.compact_map(&.as_s?)) || [] of String
      removed = @client.options.array?("sponsorblock_remove").try(&.compact_map(&.as_s?)) || [] of String
      (marked + removed).uniq
    end

    private def fetch_segments(video_id : String, categories : Array(String)) : Array(JSON::Any)
      api = @client.options.string?("sponsorblock_api") || "https://sponsor.ajay.app"
      api = "https://#{api}" unless api.starts_with?("http://") || api.starts_with?("https://")
      hash_prefix = Digest::SHA256.hexdigest(video_id)[0, 4]
      query = URI::Params.encode({
        "service"     => "YouTube",
        "categories"  => categories.to_json,
        "actionTypes" => %w[skip poi chapter].to_json,
      })
      url = "#{api.rstrip('/')}/api/skipSegments/#{hash_prefix}?#{query}"
      response = @client.send_request(Networking::Request.new(url))
      JSON.parse(response.text).as_a.each do |entry|
        values = entry.as_h
        return values["segments"]?.try(&.as_a?) || [] of JSON::Any if values["videoID"]?.try(&.as_s?) == video_id
      end
      [] of JSON::Any
    end

    private def valid_duration?(
      segment : Hash(String, JSON::Any),
      start_time : Float64,
      end_time : Float64,
      duration : Float64?,
    ) : Bool
      return true unless duration
      reported = segment["videoDuration"]?.try { |value| json_number(value) }
      return true unless reported && reported > 0
      difference = (duration - reported).abs
      length = end_time - start_time
      difference < 1 || (difference < 5 && length > 0 && difference / length < 0.05)
    end

    private def json_number(value : JSON::Any) : Float64?
      value.as_f? || value.as_i64?.try(&.to_f64)
    end
  end

  class ModifyChaptersPostProcessor < PostProcessor
    alias Chapter = Hash(String, JSON::Any)
    alias SponsorCategory = Tuple(String, Float64, Float64, String)
    alias ConcatOptions = Hash(String, String)

    DEFAULT_SPONSOR_TITLE = "[SponsorBlock]: %(category_names)l"
    TINY_CHAPTER_DURATION = 1.0
    SUPPORTED_SUBTITLES   = %w[ass lrc srt vtt]

    def key : String
      "ModifyChapters"
    end

    def run(info : Info) : Info
      source = info.string?("filepath") ||
               raise PostProcessingError.new("Chapter removal input filename is missing")
      chapters = duplicate_chapters(info.array?("chapters"))
      sponsor_chapters = duplicate_chapters(info.array?("sponsorblock_chapters"))
      duration = media_duration(info, source)
      mark_chapters_to_remove(chapters, sponsor_chapters, duration)
      return info if chapters.empty? && sponsor_chapters.empty?

      if chapters.empty?
        chapters << {
          "start_time" => JSON::Any.new(0.0),
          "end_time"   => JSON::Any.new(duration),
          "title"      => JSON::Any.new(info.title),
        }
      end

      arranged, cuts = arrange_chapters(
        (chapters + sponsor_chapters).map { |chapter| JSON::Any.new(chapter) },
      )
      info["chapters"] = JSON::Any.new(arranged)
      return info if cuts.empty?
      if arranged.empty?
        @client.warning("You requested removal of the entire video, which is not possible")
        return info
      end

      info["duration"] = chapter_number(arranged.last.as_h, "end_time")
      concat_options = make_concat_options(cuts, duration)
      transformations = [{source, false}] of Tuple(String, Bool)
      supported_subtitles(info).each { |path| transformations << {path, true} }

      outputs = [] of Tuple(String, String)
      begin
        transformations.each do |path, subtitle|
          output = cut_file(
            path,
            cuts,
            concat_options,
            @client.options.bool?("force_keyframes_at_cuts") == true && !subtitle,
          )
          outputs << {path, output}
        end
        replace_cut_files(outputs)
      rescue error
        outputs.each { |_, output| File.delete?(output) }
        raise error
      end
      info
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to remove chapters: #{error.message}", cause: error)
    end

    def arrange_chapters(
      values : Array(JSON::Any),
    ) : Tuple(Array(JSON::Any), Array(JSON::Any))
      chapters = values.map { |value| deep_dup(value.as_h) }
      return {[] of JSON::Any, [] of JSON::Any} if chapters.empty?

      cuts = [] of Chapter
      new_chapters = [] of Chapter
      queue = chapters.each_with_index.map do |chapter, index|
        {chapter_number(chapter, "start_time"), index, chapter}
      end.to_a
      sort_chapter_queue(queue)
      _, current_index, current = queue.shift

      until queue.empty?
        _, index, chapter = queue.shift
        if chapter_number(current, "end_time") <= chapter_number(chapter, "start_time")
          current["remove"]?.try(&.as_bool?) == true ? append_cut(cuts, current) : append_chapter(new_chapters, cuts, current)
          current_index, current = index, chapter
          next
        end

        if current["remove"]?.try(&.as_bool?) == true
          if chapter["remove"]?.try(&.as_bool?) == true
            current["end_time"] = JSON::Any.new(
              Math.max(chapter_number(current, "end_time"), chapter_number(chapter, "end_time")),
            )
          elsif chapter_number(current, "end_time") < chapter_number(chapter, "end_time")
            chapter["start_time"] = JSON::Any.new(chapter_number(current, "end_time"))
            chapter["_was_cut"] = JSON::Any.new(true)
            push_chapter(queue, index, chapter)
          end
        elsif chapter["remove"]?.try(&.as_bool?) == true
          current["_was_cut"] = JSON::Any.new(true)
          if chapter_number(current, "end_time") <= chapter_number(chapter, "end_time")
            current["end_time"] = JSON::Any.new(chapter_number(chapter, "start_time"))
            append_chapter(new_chapters, cuts, current)
            current_index, current = index, chapter
            next
          end

          if current.has_key?("_categories")
            after = deep_dup(current)
            after["start_time"] = JSON::Any.new(chapter_number(chapter, "end_time"))
            before_categories = [] of SponsorCategory
            after_categories = [] of SponsorCategory
            categories(current).each do |category|
              before_categories << category if category[1] < chapter_number(chapter, "start_time")
              after_categories << category if category[2] > chapter_number(chapter, "end_time")
            end
            set_categories(current, before_categories)
            set_categories(after, after_categories)
            if before_categories != after_categories
              push_chapter(queue, current_index, after)
              current["end_time"] = JSON::Any.new(chapter_number(chapter, "start_time"))
              append_chapter(new_chapters, cuts, current)
              current_index, current = index, chapter
              next
            end
          end
          cut_index = append_cut(cuts, chapter)
          current["cut_idx"] ||= JSON::Any.new(cut_index.to_i64)
        elsif current.has_key?("_categories") && !chapter.has_key?("_categories")
          if chapter_number(current, "end_time") < chapter_number(chapter, "end_time")
            chapter["start_time"] = JSON::Any.new(chapter_number(current, "end_time"))
            chapter["_was_cut"] = JSON::Any.new(true)
            push_chapter(queue, index, chapter)
          end
        else
          unless chapter.has_key?("_categories")
            raise PostProcessingError.new("Overlapping normal chapters are not supported")
          end
          current["_was_cut"] = JSON::Any.new(true)
          chapter["_was_cut"] = JSON::Any.new(true)
          if chapter_number(current, "end_time") > chapter_number(chapter, "end_time")
            after = deep_dup(current)
            after["start_time"] = JSON::Any.new(chapter_number(chapter, "end_time"))
            push_chapter(queue, current_index, after)
          elsif chapter_number(chapter, "end_time") > chapter_number(current, "end_time")
            after = deep_dup(chapter)
            after["start_time"] = JSON::Any.new(chapter_number(current, "end_time"))
            push_chapter(queue, current_index, after)
            chapter["end_time"] = JSON::Any.new(chapter_number(current, "end_time"))
          end
          if current.has_key?("_categories")
            set_categories(chapter, categories(current) + categories(chapter))
          end
          chapter["cut_idx"] = current["cut_idx"] if current["cut_idx"]?
          current["end_time"] = JSON::Any.new(chapter_number(chapter, "start_time"))
          append_chapter(new_chapters, cuts, current)
          current_index, current = index, chapter
        end
      end

      current["remove"]?.try(&.as_bool?) == true ? append_cut(cuts, current) : append_chapter(new_chapters, cuts, current)
      {
        rename_and_remove_tiny(new_chapters).map { |chapter| JSON::Any.new(chapter) },
        cuts.map { |chapter| JSON::Any.new(clean_cut(chapter)) },
      }
    end

    def make_concat_options(cuts : Array(JSON::Any), duration : Float64) : Array(ConcatOptions)
      options = [ConcatOptions.new]
      cuts.each do |value|
        cut = value.as_h
        start_time = chapter_number(cut, "start_time")
        end_time = chapter_number(cut, "end_time")
        if start_time == 0
          options.last["inpoint"] = six_places(end_time)
          next
        end
        options.last["outpoint"] = six_places(start_time)
        if end_time < duration
          options << {"inpoint" => six_places(end_time)}
        end
      end
      options
    end

    def concat_spec(source : String, options : Array(ConcatOptions)) : String
      String.build do |output|
        output << "ffconcat version 1.0\n"
        options.each do |directives|
          output << "file " << quote_for_ffmpeg("file:#{source}") << '\n'
          %w[inpoint outpoint duration].each do |directive|
            if value = directives[directive]?
              output << directive << ' ' << value << '\n'
            end
          end
        end
      end
    end

    def quote_for_ffmpeg(value : String) : String
      quoted = value.gsub("'", "'\\''").gsub("'''", "'")
      quoted = quoted.starts_with?("'") ? quoted[1..] : "'#{quoted}"
      quoted.ends_with?("'") ? quoted[...-1] : "#{quoted}'"
    end

    private def mark_chapters_to_remove(
      chapters : Array(Chapter),
      sponsor_chapters : Array(Chapter),
      duration : Float64,
    )
      removal_patterns = [] of Regex
      manual_ranges = [] of Tuple(Float64, Float64)
      @client.options.array?("remove_chapters").try do |entries|
        entries.compact_map(&.as_s?).each do |entry|
          if entry.starts_with?('*')
            manual_ranges.concat(parse_ranges(entry, duration))
          else
            begin
              removal_patterns << Regex.new(entry)
            rescue error : ArgumentError
              raise UsageError.new("Invalid --remove-chapters regex #{entry.inspect}: #{error.message}")
            end
          end
        end
      end

      chapters.each do |chapter|
        title = chapter["title"]?.try(&.as_s?) || ""
        chapter["remove"] = JSON::Any.new(true) if removal_patterns.any?(&.matches?(title))
      end

      categories_to_remove = @client.options.array?("sponsorblock_remove")
        .try(&.compact_map(&.as_s?).to_set) || Set(String).new
      sponsor_chapters.each do |chapter|
        category = chapter["category"]?.try(&.as_s?)
        chapter["remove"] = JSON::Any.new(true) if category && categories_to_remove.includes?(category)
      end

      manual_ranges.each do |start_time, end_time|
        sponsor_chapters << {
          "start_time"  => JSON::Any.new(start_time),
          "end_time"    => JSON::Any.new(end_time),
          "category"    => JSON::Any.new("manually_removed"),
          "_categories" => JSON::Any.new([
            JSON::Any.new([
              JSON::Any.new("manually_removed"),
              JSON::Any.new(start_time),
              JSON::Any.new(end_time),
              JSON::Any.new("Manually removed"),
            ]),
          ]),
          "remove" => JSON::Any.new(true),
        }
      end
    end

    private def parse_ranges(value : String, duration : Float64) : Array(Tuple(Float64, Float64))
      value.lchop('*').split(',').map do |entry|
        start_text, separator, end_text = entry.strip.partition('-')
        if separator.empty?
          raise UsageError.new("Invalid chapter range #{value.inspect}; expected *START-END")
        end
        start_time = parse_time(start_text, 0.0)
        end_time = parse_time(end_text, duration)
        if start_time < 0 || end_time < 0 || end_time < start_time
          raise UsageError.new("Invalid chapter range #{entry.inspect}")
        end
        {Math.min(start_time, duration), Math.min(end_time, duration)}
      end
    end

    private def parse_time(value : String, fallback : Float64) : Float64
      text = value.strip
      return fallback if text.empty? || text == "inf"
      parts = text.split(':')
      number = 0.0
      parts.each do |part|
        parsed = part.to_f64?
        raise UsageError.new("Invalid timestamp #{value.inspect}") unless parsed
        number = number * 60 + parsed
      end
      number
    end

    private def duplicate_chapters(values : Array(JSON::Any)?) : Array(Chapter)
      (values || [] of JSON::Any).map { |value| deep_dup(value.as_h) }
    end

    private def deep_dup(value : Chapter) : Chapter
      JSON.parse(JSON::Any.new(value).to_json).as_h
    end

    private def append_cut(cuts : Array(Chapter), chapter : Chapter) : Int32
      if previous = cuts.last?
        if chapter_number(previous, "end_time") >= chapter_number(chapter, "start_time")
          previous["end_time"] = JSON::Any.new(
            Math.max(chapter_number(previous, "end_time"), chapter_number(chapter, "end_time")),
          )
          return cuts.size - 1
        end
      end
      cuts << chapter
      cuts.size - 1
    end

    private def append_chapter(
      chapters : Array(Chapter),
      cuts : Array(Chapter),
      chapter : Chapter,
    )
      length = chapter_number(chapter, "end_time") -
               chapter_number(chapter, "start_time") -
               excess_duration(chapter, cuts)
      return if length <= 0
      start_time = chapters.last?.try { |previous| chapter_number(previous, "end_time") } || 0.0
      chapter["start_time"] = JSON::Any.new(start_time)
      chapter["end_time"] = JSON::Any.new(start_time + length)
      chapters << chapter
    end

    private def excess_duration(chapter : Chapter, cuts : Array(Chapter)) : Float64
      cut_index = chapter.delete("cut_idx").try(&.as_i64?).try(&.to_i) || cuts.size
      excess = 0.0
      while cut_index < cuts.size
        cut = cuts[cut_index]
        break if chapter_number(cut, "start_time") >= chapter_number(chapter, "end_time")
        if chapter_number(cut, "end_time") > chapter_number(chapter, "start_time")
          excess += Math.min(chapter_number(cut, "end_time"), chapter_number(chapter, "end_time"))
          excess -= Math.max(chapter_number(cut, "start_time"), chapter_number(chapter, "start_time"))
        end
        cut_index += 1
      end
      excess
    end

    private def rename_and_remove_tiny(chapters : Array(Chapter)) : Array(Chapter)
      result = [] of Chapter
      chapters.each_with_index do |chapter, index|
        tiny = (chapter.has_key?("_was_cut") || chapter.has_key?("_categories")) &&
               chapter_number(chapter, "end_time") - chapter_number(chapter, "start_time") < TINY_CHAPTER_DURATION
        if tiny
          if result.empty?
            if following = chapters[index + 1]?
              following["start_time"] = chapter["start_time"]
              next
            end
          else
            previous = result.last
            if following = chapters[index + 1]?
              previous_is_sponsor = previous.has_key?("categories")
              following_is_sponsor = following.has_key?("_categories")
              if (!chapter.has_key?("_categories") && previous_is_sponsor && !following_is_sponsor) ||
                 (chapter.has_key?("_categories") && !previous_is_sponsor && following_is_sponsor)
                following["start_time"] = chapter["start_time"]
                next
              end
            end
            previous["end_time"] = chapter["end_time"]
            next
          end
        end

        chapter.delete("_was_cut")
        sponsor_categories = categories(chapter)
        chapter.delete("_categories")
        unless sponsor_categories.empty?
          primary = sponsor_categories.min_by { |category| category[2] - category[1] }
          category_names = ordered_unique(sponsor_categories.map(&.[3]))
          chapter["category"] = JSON::Any.new(primary[0])
          chapter["categories"] = JSON::Any.new(
            ordered_unique(sponsor_categories.map(&.[0])).map { |item| JSON::Any.new(item) },
          )
          chapter["name"] = JSON::Any.new(primary[3])
          chapter["category_names"] = JSON::Any.new(
            category_names.map { |item| JSON::Any.new(item) },
          )
          template = @client.options.string?("sponsorblock_chapter_title") || DEFAULT_SPONSOR_TITLE
          chapter["title"] = JSON::Any.new(
            OutputTemplate.new(na_placeholder: "").render(
              template,
              Info.new(chapter.dup),
              sanitize: false,
            ),
          )
          if previous = result.last?
            if previous.has_key?("categories") && previous["title"]? == chapter["title"]?
              previous["end_time"] = chapter["end_time"]
              next
            end
          end
        end
        result << chapter
      end
      result
    end

    private def clean_cut(chapter : Chapter) : Chapter
      cleaned = chapter.dup
      cleaned.delete("title")
      cleaned.delete("_categories")
      cleaned
    end

    private def categories(chapter : Chapter) : Array(SponsorCategory)
      chapter["_categories"]?.try(&.as_a?).try do |values|
        return values.map do |value|
          fields = value.as_a
          {
            fields[0].as_s,
            json_number(fields[1]),
            json_number(fields[2]),
            fields[3].as_s,
          }
        end
      end
      [] of SponsorCategory
    end

    private def set_categories(chapter : Chapter, values : Array(SponsorCategory))
      chapter["_categories"] = JSON::Any.new(values.map do |category|
        JSON::Any.new([
          JSON::Any.new(category[0]),
          JSON::Any.new(category[1]),
          JSON::Any.new(category[2]),
          JSON::Any.new(category[3]),
        ])
      end)
    end

    private def ordered_unique(values : Array(String)) : Array(String)
      result = [] of String
      values.each { |value| result << value unless result.includes?(value) }
      result
    end

    private def push_chapter(
      queue : Array(Tuple(Float64, Int32, Chapter)),
      index : Int32,
      chapter : Chapter,
    )
      queue << {chapter_number(chapter, "start_time"), index, chapter}
      sort_chapter_queue(queue)
    end

    private def sort_chapter_queue(queue : Array(Tuple(Float64, Int32, Chapter)))
      queue.sort_by! { |entry| {entry[0], entry[1]} }
    end

    private def chapter_number(chapter : Chapter, key : String) : Float64
      value = chapter[key]? ||
              raise PostProcessingError.new("Chapter is missing #{key}")
      json_number(value)
    end

    private def json_number(value : JSON::Any) : Float64
      value.as_f? || value.as_i64?.try(&.to_f64) ||
        raise PostProcessingError.new("Chapter timestamp is not numeric")
    end

    private def media_duration(info : Info, source : String) : Float64
      probed = probe_duration(source)
      return probed if probed && probed > 0
      if duration = info.float?("duration")
        return duration
      end
      chapters = info.array?("chapters")
      return chapter_number(chapters.last.as_h, "end_time") if chapters && !chapters.empty?
      raise PostProcessingError.new("Unable to determine video duration")
    end

    private def probe_duration(source : String) : Float64?
      path = ffprobe_path
      return unless @client.process_runner.executable_available?(path)
      result = @client.process_runner.run(path, [
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        source,
      ])
      return unless result.success?
      result.output.strip.to_f64?
    rescue PostProcessingError
      nil
    end

    private def ffprobe_path : String
      location = @client.options.string?("ffmpeg_location")
      return "ffprobe" unless location
      if File.directory?(location)
        executable = {{ flag?(:win32) ? "ffprobe.exe" : "ffprobe" }}
        return File.join(location, executable)
      end
      directory = Path.new(location).parent
      executable = {{ flag?(:win32) ? "ffprobe.exe" : "ffprobe" }}
      File.join(directory, executable)
    end

    private def cut_file(
      source : String,
      cuts : Array(JSON::Any),
      options : Array(ConcatOptions),
      force_keyframes : Bool,
    ) : String
      concat_file = nil.as(String?)
      concat_source = source
      keyframe_file = nil
      if force_keyframes
        keyframe_file = prepend_extension(source, "keyframes.temp")
        File.delete?(keyframe_file)
        timestamps = cuts.flat_map do |value|
          chapter = value.as_h
          [chapter_number(chapter, "start_time"), chapter_number(chapter, "end_time")]
        end.uniq.reject(&.zero?)
        result = @client.process_runner.run(
          ffmpeg_path,
          [
            "-y", "-i", source,
            "-map", "0", "-dn", "-ignore_unknown",
            "-force_key_frames", timestamps.map { |time| six_places(time) }.join(','),
            keyframe_file,
          ],
        )
        check_ffmpeg_result(result, keyframe_file, "keyframe generation")
        concat_source = keyframe_file
      end

      output = prepend_extension(source, "temp")
      concat_file = "#{output}.concat"
      File.delete?(output)
      File.write(concat_file, concat_spec(concat_source, options))
      arguments = [
        "-y", "-hide_banner", "-nostdin",
        "-f", "concat", "-safe", "0", "-i", concat_file,
        "-map", "0", "-dn", "-ignore_unknown", "-c", "copy",
      ]
      extension = Path.new(source).extension.lstrip('.').downcase
      arguments.concat(["-c:s", "mov_text"]) if extension.in?("mp4", "mov", "m4a")
      arguments << output
      result = @client.process_runner.run(ffmpeg_path, arguments)
      check_ffmpeg_result(result, output, "chapter removal")
      output
    ensure
      File.delete?(concat_file) if concat_file
      File.delete?(keyframe_file) if keyframe_file
    end

    private def check_ffmpeg_result(result : ProcessResult, output : String, action : String)
      unless result.success?
        File.delete?(output)
        detail = result.error.strip
        detail = "exit code #{result.exit_code}" if detail.empty?
        raise PostProcessingError.new("ffmpeg #{action} failed: #{detail}")
      end
      unless File.exists?(output)
        raise PostProcessingError.new("ffmpeg completed without creating chapter output")
      end
    end

    private def replace_cut_files(outputs : Array(Tuple(String, String)))
      backups = [] of Tuple(String, String)
      begin
        outputs.each do |source, output|
          backup = prepend_extension(source, "uncut")
          File.delete?(backup)
          File.rename(source, backup)
          backups << {source, backup}
          File.rename(output, source)
        end
        backups.each { |_, backup| File.delete?(backup) }
      rescue error
        backups.reverse_each do |source, backup|
          File.delete?(source)
          File.rename(backup, source) if File.exists?(backup)
        end
        raise error
      end
    end

    private def supported_subtitles(info : Info) : Array(String)
      paths = [] of String
      info.hash?("requested_subtitles").try do |subtitles|
        subtitles.each_value do |value|
          subtitle = value.as_h
          path = subtitle["filepath"]?.try(&.as_s?)
          next unless path && File.exists?(path)
          extension = subtitle["ext"]?.try(&.as_s?) ||
                      Path.new(path).extension.lstrip('.')
          if SUPPORTED_SUBTITLES.includes?(extension)
            paths << path
          else
            @client.warning("Cannot remove chapters from external #{extension} subtitle #{path}")
          end
        end
      end
      paths
    end

    private def six_places(value : Float64) : String
      "%.6f" % value
    end

    private def prepend_extension(path : String, prefix : String) : String
      extension = Path.new(path).extension
      return "#{path}.#{prefix}" if extension.empty?
      "#{path.rchop(extension)}.#{prefix}#{extension}"
    end

    private def ffmpeg_path : String
      location = @client.options.string?("ffmpeg_location")
      return "ffmpeg" unless location
      return location unless File.directory?(location)
      executable = {{ flag?(:win32) ? "ffmpeg.exe" : "ffmpeg" }}
      File.join(location, executable)
    end
  end

  class FFmpegSplitChaptersPostProcessor < PostProcessor
    DEFAULT_TEMPLATE = "%(title)s - %(section_number)03d %(section_title)s [%(id)s].%(ext)s"

    def key : String
      "FFmpegSplitChapters"
    end

    def run(info : Info) : Info
      chapters = info.array?("chapters")
      unless chapters && !chapters.empty?
        @client.info_log("[SplitChapters] Chapter information is unavailable")
        return info
      end
      source = info.string?("filepath") ||
               raise PostProcessingError.new("Chapter split input filename is missing")
      input = source
      keyframe_file = nil
      created = [] of String

      if @client.options.bool?("force_keyframes_at_cuts") == true && chapters.size > 1
        keyframe_file = prepend_extension(source, "keyframes.temp")
        timestamps = chapters.compact_map do |chapter|
          chapter.as_h["start_time"]?.try { |value| json_number(value) }
        end.uniq.reject(&.zero?)
        result = @client.process_runner.run(ffmpeg_path, [
          "-y", "-i", source,
          "-map", "0", "-dn", "-ignore_unknown",
          "-force_key_frames", timestamps.map { |time| six_places(time) }.join(','),
          keyframe_file,
        ])
        check_result(result, keyframe_file, "keyframe generation")
        input = keyframe_file
      end

      chapters.each_with_index do |value, index|
        chapter = value.as_h
        start_time = json_number(chapter["start_time"]?) ||
                     raise PostProcessingError.new("Chapter start time is missing")
        end_time = json_number(chapter["end_time"]?) ||
                   info.float?("duration") ||
                   raise PostProcessingError.new("Chapter end time is missing")
        destination = chapter_filename(info, chapter, index + 1)
        FileUtils.mkdir_p(Path.new(destination).parent)
        temporary = prepend_extension(destination, "temp")
        File.delete?(temporary)
        result = @client.process_runner.run(ffmpeg_path, [
          "-y", "-ss", start_time.to_s,
          "-t", (end_time - start_time).to_s,
          "-i", input,
          "-map", "0", "-dn", "-ignore_unknown", "-c", "copy",
          temporary,
        ])
        check_result(result, temporary, "chapter splitting")
        File.delete?(destination)
        File.rename(temporary, destination)
        created << destination
        chapter["filepath"] = JSON::Any.new(destination)
      end
      info["chapters"] = JSON::Any.new(chapters)
      info
    rescue error : PostProcessingError
      created.try(&.each { |path| File.delete?(path) })
      raise error
    rescue error
      created.try(&.each { |path| File.delete?(path) })
      raise PostProcessingError.new("Unable to split chapters: #{error.message}", cause: error)
    ensure
      File.delete?(keyframe_file) if keyframe_file
    end

    private def chapter_filename(info : Info, chapter : Hash(String, JSON::Any), number : Int32) : String
      values = info.data.dup
      values["section_number"] = JSON::Any.new(number.to_i64)
      values["section_title"] = chapter["title"]? || JSON::Any.new(nil)
      values["section_start"] = chapter["start_time"]? || JSON::Any.new(nil)
      values["section_end"] = chapter["end_time"]? || JSON::Any.new(nil)
      template = @client.options.hash?("outtmpl").try(&.["chapter"]?).try(&.as_s?) ||
                 DEFAULT_TEMPLATE
      rendered = output_template.render(template, Info.new(values))
      return rendered if Path.new(rendered).absolute?

      paths = @client.options.hash?("paths")
      root = paths.try(&.["chapter"]?).try(&.as_s?)
      unless root
        root = info.sidecar["move_plan"]?.as?(MovePlan).try(&.temporary_root)
        root ||= paths.try(&.["home"]?).try(&.as_s?)
      end
      root ? File.join(root, rendered) : rendered
    end

    private def output_template : OutputTemplate
      OutputTemplate.new(
        na_placeholder: @client.options.string?("outtmpl_na_placeholder") || "NA",
        restrict_filenames: @client.options.bool?("restrictfilenames") == true,
        windows_filenames: @client.options.bool?("windowsfilenames"),
        trim_file_name: (@client.options.int?("trim_file_name") || 0).to_i,
        autonumber_start: @client.options.int?("autonumber_start") || 1_i64,
        autonumber_size: (@client.options.int?("autonumber_size") || 5).to_i,
      )
    end

    private def json_number(value : JSON::Any?) : Float64?
      value.try(&.as_f?) || value.try(&.as_i64?).try(&.to_f64)
    end

    private def check_result(result : ProcessResult, output : String, action : String)
      unless result.success?
        File.delete?(output)
        detail = result.error.strip
        detail = "exit code #{result.exit_code}" if detail.empty?
        raise PostProcessingError.new("ffmpeg #{action} failed: #{detail}")
      end
      unless File.exists?(output)
        raise PostProcessingError.new("ffmpeg completed without creating split chapter output")
      end
    end

    private def prepend_extension(path : String, prefix : String) : String
      extension = Path.new(path).extension
      return "#{path}.#{prefix}" if extension.empty?
      "#{path.rchop(extension)}.#{prefix}#{extension}"
    end

    private def ffmpeg_path : String
      location = @client.options.string?("ffmpeg_location")
      return "ffmpeg" unless location
      return location unless File.directory?(location)
      executable = {{ flag?(:win32) ? "ffmpeg.exe" : "ffmpeg" }}
      File.join(location, executable)
    end

    private def six_places(value : Float64) : String
      "%.6f" % value
    end
  end

  class FFmpegConcatPostProcessor < PostProcessor
    def key : String
      "FFmpegConcat"
    end

    def run(info : Info) : Info
      entries = info.array?("entries") || [] of JSON::Any
      return info if entries.empty?

      inputs = [] of String
      extensions = [] of String
      entries.each do |entry|
        values = entry.as_h
        downloads = values["requested_downloads"]?.try(&.as_a?) ||
                    raise PostProcessingError.new("Aborting concatenation because some downloads failed")
        if downloads.size != 1
          raise PostProcessingError.new(
            "Concatenation is not supported when downloading multiple separate formats",
          )
        end
        download = downloads.first.as_h
        path = download["filepath"]?.try(&.as_s?)
        unless path && File.exists?(path)
          raise PostProcessingError.new("Aborting concatenation because some downloads failed")
        end
        inputs << path
        extensions << (
          download["ext"]?.try(&.as_s?) ||
          values["ext"]?.try(&.as_s?) ||
          Path.new(path).extension.lstrip('.')
        )
      end

      extension = extensions.uniq.size == 1 ? extensions.first : "mkv"
      destination = playlist_filename(info, extension)
      FileUtils.mkdir_p(Path.new(destination).parent)
      if inputs.size == 1
        unless Path.new(inputs.first).expand == Path.new(destination).expand
          File.delete?(destination)
          FileUtils.mv(inputs.first, destination)
        end
      else
        validate_codecs(inputs)
        concatenate(inputs, destination, extension)
        inputs.each { |path| File.delete?(path) unless Path.new(path).expand == Path.new(destination).expand }
      end

      descriptor = JSON::Any.new({
        "filepath" => JSON::Any.new(destination),
        "ext"      => JSON::Any.new(extension),
      })
      info["requested_downloads"] = JSON::Any.new([descriptor])
      info["filepath"] = destination
      info["ext"] = extension
      info
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to concatenate playlist: #{error.message}", cause: error)
    end

    private def validate_codecs(inputs : Array(String))
      probe = ffprobe_path
      return unless @client.process_runner.executable_available?(probe)
      signatures = inputs.map do |path|
        result = @client.process_runner.run(probe, [
          "-v", "error",
          "-show_entries", "stream=codec_name",
          "-of", "json",
          path,
        ])
        unless result.success?
          raise PostProcessingError.new("Unable to inspect playlist streams: #{result.error.strip}")
        end
        JSON.parse(result.output)["streams"].as_a.map do |stream|
          stream.as_h["codec_name"]?.try(&.as_s?) || ""
        end
      rescue error : JSON::ParseException | KeyError | TypeCastError
        raise PostProcessingError.new("Unable to inspect playlist streams: #{error.message}")
      end
      if signatures.uniq.size > 1
        raise PostProcessingError.new(
          "The files have different streams/codecs and cannot be concatenated. " \
          "Either select different formats or --recode-video them to a common format",
        )
      end
    end

    private def concatenate(inputs : Array(String), destination : String, extension : String)
      temporary = prepend_extension(destination, "temp")
      concat_file = "#{temporary}.concat"
      File.delete?(temporary)
      File.write(concat_file, concat_spec(inputs))
      arguments = [
        "-y", "-hide_banner", "-nostdin",
        "-f", "concat", "-safe", "0", "-i", concat_file,
        "-map", "0", "-dn", "-ignore_unknown", "-c", "copy",
      ]
      arguments.concat(["-c:s", "mov_text"]) if extension.in?("mp4", "mov", "m4a")
      arguments << temporary
      result = @client.process_runner.run(ffmpeg_path, arguments)
      unless result.success?
        File.delete?(temporary)
        detail = result.error.strip
        detail = "exit code #{result.exit_code}" if detail.empty?
        raise PostProcessingError.new("ffmpeg playlist concatenation failed: #{detail}")
      end
      unless File.exists?(temporary)
        raise PostProcessingError.new("ffmpeg completed without creating concatenated output")
      end
      File.delete?(destination)
      File.rename(temporary, destination)
    ensure
      File.delete?(concat_file) if concat_file
    end

    private def concat_spec(inputs : Array(String)) : String
      String.build do |output|
        output << "ffconcat version 1.0\n"
        inputs.each do |path|
          output << "file " << quote_for_ffmpeg("file:#{path}") << '\n'
        end
      end
    end

    private def quote_for_ffmpeg(value : String) : String
      quoted = value.gsub("'", "'\\''").gsub("'''", "'")
      quoted = quoted.starts_with?("'") ? quoted[1..] : "'#{quoted}"
      quoted.ends_with?("'") ? quoted[...-1] : "#{quoted}'"
    end

    private def playlist_filename(info : Info, extension : String) : String
      values = info.data.dup
      values["ext"] = JSON::Any.new(extension)
      unless values["playlist"]?
        if title = values["title"]? || values["id"]?
          values["playlist"] = title
        end
      end
      unless values["playlist_id"]?
        if id = values["id"]?
          values["playlist_id"] = id
        end
      end
      unless values["playlist_title"]?
        if title = values["title"]?
          values["playlist_title"] = title
        end
      end
      template = @client.options.hash?("outtmpl").try(&.["pl_video"]?).try(&.as_s?) ||
                 @client.options.hash?("outtmpl").try(&.["default"]?).try(&.as_s?) ||
                 @client.options.string?("outtmpl") ||
                 "%(title)s [%(id)s].%(ext)s"
      rendered = output_template.render(template, Info.new(values))
      return rendered if Path.new(rendered).absolute?

      paths = @client.options.hash?("paths")
      root = paths.try(&.["pl_video"]?).try(&.as_s?) ||
             paths.try(&.["home"]?).try(&.as_s?)
      root ? File.join(root, rendered) : rendered
    end

    private def output_template : OutputTemplate
      OutputTemplate.new(
        na_placeholder: @client.options.string?("outtmpl_na_placeholder") || "NA",
        restrict_filenames: @client.options.bool?("restrictfilenames") == true,
        windows_filenames: @client.options.bool?("windowsfilenames"),
        trim_file_name: (@client.options.int?("trim_file_name") || 0).to_i,
        autonumber_start: @client.options.int?("autonumber_start") || 1_i64,
        autonumber_size: (@client.options.int?("autonumber_size") || 5).to_i,
      )
    end

    private def prepend_extension(path : String, prefix : String) : String
      extension = Path.new(path).extension
      return "#{path}.#{prefix}" if extension.empty?
      "#{path.rchop(extension)}.#{prefix}#{extension}"
    end

    private def ffmpeg_path : String
      location = @client.options.string?("ffmpeg_location")
      return "ffmpeg" unless location
      return location unless File.directory?(location)
      executable = {{ flag?(:win32) ? "ffmpeg.exe" : "ffmpeg" }}
      File.join(location, executable)
    end

    private def ffprobe_path : String
      location = @client.options.string?("ffmpeg_location")
      return "ffprobe" unless location
      if File.directory?(location)
        executable = {{ flag?(:win32) ? "ffprobe.exe" : "ffprobe" }}
        return File.join(location, executable)
      end
      executable = {{ flag?(:win32) ? "ffprobe.exe" : "ffprobe" }}
      File.join(Path.new(location).parent, executable)
    end
  end

  class XAttrMetadataPostProcessor < PostProcessor
    MAPPING = {
      "user.xdg.referrer.url"                => "webpage_url",
      "user.dublincore.title"                => "title",
      "user.dublincore.date"                 => "upload_date",
      "user.dublincore.contributor"          => "uploader",
      "user.dublincore.format"               => "format",
      "user.dublincore.description"          => "description",
      "com.apple.metadata:kMDItemWhereFroms" => "webpage_url",
    }

    APPLE_PLIST_TEMPLATE = <<-XML
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <array>
    	<string>%s</string>
    </array>
    </plist>
    XML

    def key : String
      "XAttrMetadata"
    end

    def run(info : Info) : Info
      path = info.string?("filepath") ||
             raise PostProcessingError.new("Extended attribute input filename is missing")
      modification_time = File.info(path).modification_time
      MAPPING.each do |attribute, field|
        value = metadata_value(info[field]?)
        next unless value
        if field == "upload_date"
          value = hyphenate_date(value)
        elsif attribute == "com.apple.metadata:kMDItemWhereFroms"
          {% if flag?(:darwin) %}
            value = APPLE_PLIST_TEMPLATE % xml_escape(value)
          {% else %}
            next
          {% end %}
        end
        begin
          @client.xattr_writer.write(path, attribute, value)
        rescue error : XAttrWriteError
          case error.reason
          when .no_space?
            @client.warning("Extended attribute #{attribute.inspect} was not written: no space or quota exceeded")
          when .value_too_long?
            @client.warning("Extended attribute #{attribute.inspect} was too long")
          else
            raise PostProcessingError.new(
              "This filesystem doesn't support extended attributes: #{error.message}",
              cause: error,
            )
          end
        end
      end
      File.utime(modification_time, modification_time, path)
      info
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to write extended attributes: #{error.message}", cause: error)
    end

    private def metadata_value(value : JSON::Any?) : String?
      return unless value
      value.as_s? ||
        value.as_i64?.try(&.to_s) ||
        value.as_f?.try(&.to_s) ||
        value.as_bool?.try(&.to_s)
    end

    private def hyphenate_date(value : String) : String
      match = value.match(/\A(\d{4})(\d{2})(\d{2})\z/)
      match ? "#{match[1]}-#{match[2]}-#{match[3]}" : value
    end

    private def xml_escape(value : String) : String
      value
        .gsub('&', "&amp;")
        .gsub('<', "&lt;")
        .gsub('>', "&gt;")
        .gsub('"', "&quot;")
        .gsub('\'', "&apos;")
    end
  end

  abstract class FFmpegMediaPostProcessor < PostProcessor
    protected def resolve_mapping(source : String, mapping : String) : Tuple(String?, String?)
      mapping.downcase.split('/').each do |rule|
        input, separator, output = rule.partition('>')
        if separator.empty?
          output = input
          input = ""
        end
        input = input.strip
        output = output.strip
        next unless input.empty? || input == source
        return {output, output == source ? "already is in target format #{source}" : nil}
      end
      {nil, "could not find a mapping for #{source}"}
    end

    protected def run_ffmpeg_transform(
      source : String,
      destination : String,
      arguments : Array(String),
      description : String,
    )
      temporary = temporary_filename(destination)
      File.delete?(temporary)
      command = ["-y", "-i", source] + arguments + [temporary]
      result = @client.process_runner.run(ffmpeg_path, command)
      unless result.success?
        File.delete?(temporary)
        detail = result.error.strip
        detail = "exit code #{result.exit_code}" if detail.empty?
        raise PostProcessingError.new("ffmpeg #{description} failed: #{detail}")
      end
      unless File.exists?(temporary)
        raise PostProcessingError.new("ffmpeg completed without creating converted output")
      end

      if destination == source
        original = prepend_extension(source, "orig")
        File.delete?(original)
        File.rename(source, original)
        begin
          File.rename(temporary, destination)
          File.delete?(original) unless @client.options.bool?("keepvideo")
        rescue error
          File.rename(original, source) if File.exists?(original) && !File.exists?(source)
          raise error
        end
      else
        File.delete?(destination)
        File.rename(temporary, destination)
        File.delete?(source) unless @client.options.bool?("keepvideo")
      end
    end

    protected def replace_extension(path : String, extension : String) : String
      current = Path.new(path).extension
      stem = current.empty? ? path : path.rchop(current)
      "#{stem}.#{extension}"
    end

    protected def prepend_extension(path : String, prefix : String) : String
      extension = Path.new(path).extension
      return "#{path}.#{prefix}" if extension.empty?
      "#{path.rchop(extension)}.#{prefix}#{extension}"
    end

    protected def ffmpeg_path : String
      location = @client.options.string?("ffmpeg_location")
      return "ffmpeg" unless location
      return location unless File.directory?(location)
      executable = {{ flag?(:win32) ? "ffmpeg.exe" : "ffmpeg" }}
      File.join(location, executable)
    end

    private def temporary_filename(destination : String) : String
      extension = Path.new(destination).extension
      return "#{destination}.temp" if extension.empty?
      "#{destination.rchop(extension)}.temp#{extension}"
    end
  end

  class FFmpegExtractAudioPostProcessor < FFmpegMediaPostProcessor
    COMMON_AUDIO_EXTENSIONS = %w[aiff alac flac m4a mka mp3 ogg opus wav wma]
    SUPPORTED_FORMATS       = %w[best aac alac flac m4a mp3 opus vorbis wav]

    def key : String
      "FFmpegExtractAudio"
    end

    def run(info : Info) : Info
      source = info.string?("filepath") ||
               raise PostProcessingError.new("Audio extraction input filename is missing")
      source_extension = info.ext.downcase
      mapping = @client.options.string?("audioformat") || "best"
      target, skip_reason = resolve_mapping(source_extension, mapping)
      unless target
        @client.info_log("[ExtractAudio] Not converting audio #{source}; #{skip_reason}")
        return info
      end
      unless SUPPORTED_FORMATS.includes?(target)
        raise PostProcessingError.new("Unsupported audio conversion format #{target}")
      end
      if target == "best" && COMMON_AUDIO_EXTENSIONS.includes?(source_extension)
        @client.info_log("[ExtractAudio] Not converting audio #{source}; the file is already in a common audio format")
        return info
      end

      source_codec = normalized_audio_codec(info.string?("acodec"), source_extension)
      extension, encoder, codec_options = audio_target(target, source_codec)
      destination = replace_extension(source, extension)
      if @client.options.bool?("nopostoverwrites") == true &&
         File.exists?(destination) && destination != source
        @client.info_log("[ExtractAudio] Post-process file #{destination} exists, skipping")
        return info
      end

      arguments = ["-vn"] of String
      arguments.concat(["-acodec", encoder]) if encoder
      arguments.concat(encoder && encoder != "copy" ? quality_arguments(encoder) : codec_options)
      run_ffmpeg_transform(source, destination, arguments, "audio conversion")
      info["filepath"] = destination
      info["_filename"] = destination
      info["ext"] = extension
      info["format"] = extension
      info
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to extract audio: #{error.message}", cause: error)
    end

    private def normalized_audio_codec(codec : String?, extension : String) : String
      value = codec.try(&.downcase)
      return extension if value.nil? || value.empty? || value == "none"
      return "aac" if value.starts_with?("mp4a") || value.starts_with?("aac")
      return "mp3" if value.starts_with?("mp3")
      return "vorbis" if value.includes?("vorbis")
      return "opus" if value.includes?("opus")
      value
    end

    private def audio_target(
      target : String,
      source_codec : String,
    ) : Tuple(String, String?, Array(String))
      if source_codec == "aac" && target.in?("m4a", "best")
        return {"m4a", "copy", ["-bsf:a", "aac_adtstoasc"]}
      end
      if target == "best" || target == source_codec
        case source_codec
        when "mp3"    then return {"mp3", "copy", [] of String}
        when "aac"    then return {"m4a", "copy", ["-bsf:a", "aac_adtstoasc"]}
        when "m4a"    then return {"m4a", "copy", [] of String}
        when "opus"   then return {"opus", "copy", [] of String}
        when "vorbis" then return {"ogg", "copy", [] of String}
        when "flac"   then return {"flac", "copy", [] of String}
        when "alac"   then return {"m4a", "copy", [] of String}
        when "wav"    then return {"wav", "copy", [] of String}
        end
        return {"mp3", "libmp3lame", [] of String}
      end

      case target
      when "mp3"    then {"mp3", "libmp3lame", [] of String}
      when "aac"    then {"m4a", "aac", ["-f", "adts"]}
      when "m4a"    then {"m4a", "aac", ["-bsf:a", "aac_adtstoasc"]}
      when "opus"   then {"opus", "libopus", [] of String}
      when "vorbis" then {"ogg", "libvorbis", [] of String}
      when "flac"   then {"flac", "flac", [] of String}
      when "alac"   then {"m4a", "alac", [] of String}
      when "wav"    then {"wav", nil, ["-f", "wav"]}
      else
        raise PostProcessingError.new("Unsupported audio conversion format #{target}")
      end
    end

    private def quality_arguments(codec : String) : Array(String)
      raw = @client.options.string?("audioquality")
      return [] of String unless raw
      if match = raw.match(/\A(\d+(?:\.\d+)?)\s*[kK]\z/)
        return ["-b:a", "#{match[1]}k"]
      end
      quality = raw.to_f64?
      return [] of String unless quality
      return ["-b:a", "#{quality.to_i}k"] if quality > 10

      limits = case codec
               when "libmp3lame" then {10.0, 0.0}
               when "libvorbis"  then {0.0, 10.0}
               when "aac"        then {0.1, 4.0}
               else                   nil
               end
      return [] of String unless limits
      value = limits[1] + (limits[0] - limits[1]) * quality / 10
      ["-q:a", value.to_s]
    end
  end

  abstract class FFmpegVideoTransformPostProcessor < FFmpegMediaPostProcessor
    SUPPORTED_FORMATS = %w[
      aac aiff alac avi flac flv gif m4a mka mkv mov mp3 mp4 ogg opus
      vorbis wav webm
    ]

    def run(info : Info) : Info
      source = info.string?("filepath") ||
               raise PostProcessingError.new("#{action.titleize} input filename is missing")
      source_extension = info.ext.downcase
      mapping = format_mapping
      target, skip_reason = resolve_mapping(source_extension, mapping)
      unless target
        @client.info_log("[#{key}] Not #{action} media file #{source}; #{skip_reason}")
        return info
      end
      unless SUPPORTED_FORMATS.includes?(target)
        raise PostProcessingError.new("Unsupported #{action} format #{target}")
      end
      if skip_reason
        @client.info_log("[#{key}] Not #{action} media file #{source}; #{skip_reason}")
        return info
      end

      destination = replace_extension(source, target)
      if @client.options.bool?("nopostoverwrites") == true && File.exists?(destination)
        @client.info_log("[#{key}] Post-process file #{destination} exists, skipping")
        return info
      end
      run_ffmpeg_transform(source, destination, transform_arguments(target), action)
      info["filepath"] = destination
      info["_filename"] = destination
      info["ext"] = target
      info["format"] = target
      info
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to #{action}: #{error.message}", cause: error)
    end

    abstract def action : String
    protected abstract def format_mapping : String
    protected abstract def transform_arguments(target : String) : Array(String)
  end

  class FFmpegVideoRemuxerPostProcessor < FFmpegVideoTransformPostProcessor
    def key : String
      "FFmpegVideoRemuxer"
    end

    def action : String
      "remuxing"
    end

    protected def format_mapping : String
      @client.options.string?("remuxvideo") ||
        raise PostProcessingError.new("Video remux mapping is missing")
    end

    protected def transform_arguments(target : String) : Array(String)
      arguments = ["-map", "0", "-dn", "-ignore_unknown", "-c", "copy"]
      arguments.concat(["-c:s", "mov_text"]) if target.in?("mp4", "mov", "m4a")
      arguments
    end
  end

  class FFmpegVideoConvertorPostProcessor < FFmpegVideoTransformPostProcessor
    def key : String
      "FFmpegVideoConvertor"
    end

    def action : String
      "converting"
    end

    protected def format_mapping : String
      @client.options.string?("recodevideo") ||
        raise PostProcessingError.new("Video conversion mapping is missing")
    end

    protected def transform_arguments(target : String) : Array(String)
      arguments = ["-map", "0", "-dn", "-ignore_unknown"]
      arguments.concat(["-c:v", "libxvid", "-vtag", "XVID"]) if target == "avi"
      arguments.concat(["-c:s", "mov_text"]) if target.in?("mp4", "mov", "m4a")
      arguments
    end
  end

  class FFmpegMetadataPostProcessor < FFmpegMediaPostProcessor
    COMMON_METADATA = {
      "title"         => %w[track title],
      "date"          => %w[upload_date],
      "description"   => %w[description],
      "synopsis"      => %w[description],
      "purl"          => %w[webpage_url],
      "comment"       => %w[webpage_url],
      "track"         => %w[track_number],
      "artist"        => %w[artist artists creator creators uploader uploader_id],
      "composer"      => %w[composer composers],
      "genre"         => %w[genre genres categories tags],
      "album"         => %w[album series],
      "album_artist"  => %w[album_artist album_artists],
      "disc"          => %w[disc_number],
      "show"          => %w[series],
      "season_number" => %w[season_number],
      "episode_id"    => %w[episode episode_id],
      "episode_sort"  => %w[episode_number],
    }

    def key : String
      "FFmpegMetadata"
    end

    def run(info : Info) : Info
      source = info.string?("filepath") ||
               raise PostProcessingError.new("Metadata input filename is missing")
      extension = info.ext.downcase
      temporary_files = [] of String
      arguments = ["-y", "-i", source] of String
      output_options = stream_copy_arguments(extension)

      if add_chapters? && (chapters = info.array?("chapters")) && !chapters.empty?
        chapter_file = replace_extension(source, "meta")
        write_chapters(chapter_file, chapters)
        temporary_files << chapter_file
        arguments.concat(["-i", chapter_file])
        output_options.concat(["-map_metadata", "1"])
      end

      output_options.concat(metadata_arguments(info)) if add_metadata?
      if add_infojson?
        if extension.in?("mkv", "mka")
          if infojson = infojson_file(info, source)
            temporary_files << infojson if infojson.ends_with?(".temp.info.json")
            output_options.concat([
              "-attach", infojson,
              "-metadata:s:t", "mimetype=application/json",
              "-metadata:s:t", "filename=info.json",
            ])
          end
        elsif add_infojson? == true
          @client.info_log("[FFmpegMetadata] The info-json can only be attached to mkv/mka files")
        end
      end

      if output_options == stream_copy_arguments(extension)
        @client.info_log("[FFmpegMetadata] There isn't any metadata to add")
        return info
      end

      temporary = temporary_filename(source)
      File.delete?(temporary)
      result = @client.process_runner.run(
        ffmpeg_path,
        arguments + output_options + [temporary],
      )
      unless result.success?
        File.delete?(temporary)
        detail = result.error.strip
        detail = "exit code #{result.exit_code}" if detail.empty?
        raise PostProcessingError.new("ffmpeg metadata embedding failed: #{detail}")
      end
      unless File.exists?(temporary)
        raise PostProcessingError.new("ffmpeg completed without creating metadata output")
      end
      replace_media(temporary, source)
      info
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to embed metadata: #{error.message}", cause: error)
    ensure
      temporary_files.try(&.each { |path| File.delete?(path) })
    end

    private def add_metadata? : Bool
      @client.options.bool?("addmetadata") == true
    end

    private def add_chapters? : Bool
      value = @client.options.bool?("addchapters")
      value.nil? ? add_metadata? || sponsorblock_marked? : value
    end

    private def sponsorblock_marked? : Bool
      !(@client.options.array?("sponsorblock_mark") || [] of JSON::Any).empty?
    end

    private def add_infojson? : Bool | String | Nil
      value = @client.options["embed_infojson"]
      return "if_exists" if value.nil? && add_metadata?
      value.try(&.as_bool?) || value.try(&.as_s?)
    end

    private def metadata_arguments(info : Info) : Array(String)
      metadata = Hash(String, String).new
      COMMON_METADATA.each do |name, fields|
        if value = first_metadata_value(info, fields)
          metadata[name] = value
        end
      end

      stream_metadata = Hash(String, Hash(String, String)).new do |hash, key|
        hash[key] = Hash(String, String).new
      end
      info.data.each do |name, value|
        match = name.match(/\Ameta(\d+)?_(.+)\z/)
        next unless match
        rendered = metadata_value(value)
        next unless rendered
        if stream = match[1]?
          stream_metadata[stream][match[2]] = rendered
        else
          metadata[match[2]] = rendered
        end
      end

      arguments = ["-write_id3v1", "1"] of String
      metadata.each do |name, value|
        arguments.concat(["-metadata", "#{name}=#{value}"])
      end

      stream_index = 0
      formats = info.array?("requested_formats") || [JSON::Any.new(info.data)]
      formats.each do |format|
        values = format.as_h
        video_codec = values["vcodec"]?.try(&.as_s?)
        audio_codec = values["acodec"]?.try(&.as_s?)
        stream_count = video_codec != "none" && audio_codec != "none" ? 2 : 1
        language = values["language"]?.try(&.as_s?)
        language = ISO639.short_to_long(language) || language if language
        stream_count.times do
          values_for_stream = stream_metadata[stream_index.to_s]
          values_for_stream["language"] ||= language if language
          values_for_stream.each do |name, value|
            arguments.concat(["-metadata:s:#{stream_index}", "#{name}=#{value}"])
          end
          stream_index += 1
        end
      end
      arguments
    end

    private def first_metadata_value(info : Info, fields : Array(String)) : String?
      fields.each do |field|
        value = metadata_value(info[field]?)
        return value if value
      end
      nil
    end

    private def metadata_value(value : JSON::Any?) : String?
      return unless value
      rendered = if array = value.as_a?
                   array.compact_map { |item| scalar_metadata_value(item) }.join(", ")
                 else
                   scalar_metadata_value(value)
                 end
      return if rendered.nil? || rendered.empty?
      rendered.delete('\0')
    end

    private def scalar_metadata_value(value : JSON::Any) : String?
      value.as_s? ||
        value.as_i64?.try(&.to_s) ||
        value.as_f?.try(&.to_s) ||
        value.as_bool?.try(&.to_s)
    end

    private def stream_copy_arguments(extension : String) : Array(String)
      arguments = ["-map", "0", "-dn", "-ignore_unknown", "-c", "copy"]
      arguments.concat(["-c:s", "mov_text"]) if extension.in?("mp4", "mov", "m4a")
      if extension == "m4a"
        arguments.concat(["-vn", "-acodec", "copy"])
      end
      arguments
    end

    private def write_chapters(path : String, chapters : Array(JSON::Any))
      File.open(path, "w") do |file|
        file.puts(";FFMETADATA1")
        chapters.each do |chapter|
          values = chapter.as_h
          start_time = json_number(values["start_time"]?) || next
          end_time = json_number(values["end_time"]?) || next
          file.puts("[CHAPTER]")
          file.puts("TIMEBASE=1/1000")
          file.puts("START=#{(start_time * 1000).to_i64}")
          file.puts("END=#{(end_time * 1000).to_i64}")
          if title = values["title"]?.try(&.as_s?)
            file.puts("title=#{escape_ffmetadata(title)}")
          end
        end
      end
    end

    private def json_number(value : JSON::Any?) : Float64?
      value.try(&.as_f?) || value.try(&.as_i64?).try(&.to_f64)
    end

    private def escape_ffmetadata(value : String) : String
      value.gsub(/([\\=;#\n])/, "\\\\\\1")
    end

    private def infojson_file(info : Info, source : String) : String?
      if path = info.string?("infojson_filename")
        return path if File.exists?(path)
      end
      return unless add_infojson? == true

      path = "#{source.rchop(Path.new(source).extension)}.temp.info.json"
      File.write(path, info.to_pretty_json)
      info["infojson_filename"] = path
      path
    end

    private def replace_media(temporary : String, filename : String)
      backup = prepend_extension(filename, "original")
      File.delete?(backup)
      File.rename(filename, backup)
      begin
        File.rename(temporary, filename)
        File.delete?(backup)
      rescue error
        File.rename(backup, filename) if File.exists?(backup) && !File.exists?(filename)
        raise error
      end
    end

    private def temporary_filename(output : String) : String
      prepend_extension(output, "temp")
    end
  end

  class ExecPostProcessor < PostProcessor
    def initialize(client : Client, @commands : Array(String))
      super(client)
    end

    def key : String
      "Exec"
    end

    def run(info : Info) : Info
      @commands.each do |template|
        command = command_for(template, info)
        result = @client.process_runner.run_shell(command)
        unless result.success?
          raise PostProcessingError.new("Command returned error code #{result.exit_code}")
        end
      end
      info
    end

    private def command_for(template : String, info : Info) : String
      if template.includes?("%(")
        return output_template.render(template, info, sanitize: false)
      end
      filepath = info.string?("filepath") || info.string?("_filename")
      return template unless filepath
      quoted = shell_quote(filepath)
      template.includes?("{}") ? template.gsub("{}", quoted) : "#{template} #{quoted}"
    end

    private def output_template : OutputTemplate
      OutputTemplate.new(na_placeholder: "")
    end

    private def shell_quote(value : String) : String
      output_template.render("%(filepath)q", Info.new({
        "filepath" => JSON::Any.new(value),
      }), sanitize: false)
    end
  end

  class MoveFilesAfterDownloadPostProcessor < PostProcessor
    def key : String
      "MoveFiles"
    end

    def run(info : Info) : Info
      plan = info.sidecar["move_plan"]?.as?(MovePlan) || return info
      source = info.string?("filepath") ||
               raise PostProcessingError.new("Move input filename is missing")
      destination = replace_extension(plan.final_path, info.ext)

      move_related_files(info, plan)
      if File.exists?(source)
        move_file(source, destination)
      elsif @client.options.bool?("skip_download") != true
        @client.warning("File #{source} cannot be found")
      end
      info["filepath"] = destination
      info["_filename"] = destination
      info
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to move downloaded files: #{error.message}", cause: error)
    end

    private def move_related_files(info : Info, plan : MovePlan)
      if source = info.string?("infojson_filename")
        if destination = move_related_path(source, plan)
          info["infojson_filename"] = destination
        end
      end
      info.hash?("requested_subtitles").try do |subtitles|
        subtitles.each_value do |value|
          values = value.as_h
          move_related_path(values, plan)
        end
      end
      info.array?("thumbnails").try do |thumbnails|
        thumbnails.each { |value| move_related_path(value.as_h, plan) }
      end
      info.array?("chapters").try do |chapters|
        chapters.each { |value| move_related_path(value.as_h, plan) }
      end
      if sidecars = info.sidecar["extra_sidecar_files"]?.as?(ExtraSidecarFiles)
        sidecars.paths.map! { |source| move_related_path(source, plan) || source }
      end
    end

    private def move_related_path(values : Hash(String, JSON::Any), plan : MovePlan)
      source = values["filepath"]?.try(&.as_s?)
      return unless source && File.exists?(source)
      if destination = move_related_path(source, plan)
        values["filepath"] = JSON::Any.new(destination)
      end
    end

    private def move_related_path(source : String, plan : MovePlan) : String?
      return unless File.exists?(source)
      relative = Path.new(source).expand.relative_to?(Path.new(plan.temporary_root).expand)
      return unless relative
      destination = Path.new(plan.final_root).join(relative).to_s
      move_file(source, destination)
      destination
    end

    private def move_file(source : String, destination : String)
      return if Path.new(source).expand == Path.new(destination).expand
      unless File.exists?(source)
        @client.warning("File #{source} cannot be found")
        return
      end
      if File.exists?(destination)
        if @client.options.bool?("overwrites") == false
          @client.warning("Cannot move #{source}; #{destination} already exists")
          return
        end
        File.delete(destination)
      end
      FileUtils.mkdir_p(Path.new(destination).parent)
      FileUtils.mv(source, destination)
    end

    private def replace_extension(path : String, extension : String) : String
      current = Path.new(path).extension
      stem = current.empty? ? path : path.rchop(current)
      "#{stem}.#{extension}"
    end
  end

  class FFmpegMergerPostProcessor < PostProcessor
    def key : String
      "FFmpegMerger"
    end

    def run(info : Info) : Info
      inputs = info.sidecar["merger_inputs"]?.as?(MergerInputs) ||
               raise PostProcessingError.new("Merger input files are missing")
      output = info.string?("_filename") ||
               raise PostProcessingError.new("Merger output filename is missing")
      temporary = temporary_filename(output)
      File.delete?(temporary)

      arguments = ["-y"] of String
      inputs.paths.each { |path| arguments.concat(["-i", path]) }
      inputs.paths.each_index do |index|
        arguments.concat(["-map", "#{index}:v:0?"])
        arguments.concat(["-map", "#{index}:a:0?"])
      end
      arguments.concat(["-c", "copy", temporary])

      result = @client.process_runner.run(ffmpeg_path, arguments)
      unless result.success?
        File.delete?(temporary)
        detail = result.error.strip
        detail = "exit code #{result.exit_code}" if detail.empty?
        raise PostProcessingError.new("ffmpeg merge failed: #{detail}")
      end
      unless File.exists?(temporary)
        raise PostProcessingError.new("ffmpeg completed without creating merged output")
      end

      File.delete?(output)
      File.rename(temporary, output)
      unless @client.options.bool?("keepvideo")
        inputs.paths.each { |path| File.delete?(path) }
      end
      info["filepath"] = output
      info
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to merge formats: #{error.message}", cause: error)
    end

    private def ffmpeg_path : String
      location = @client.options.string?("ffmpeg_location")
      return "ffmpeg" unless location
      return location unless File.directory?(location)
      executable = {{ flag?(:win32) ? "ffmpeg.exe" : "ffmpeg" }}
      File.join(location, executable)
    end

    private def temporary_filename(output : String) : String
      extension = Path.new(output).extension
      stem = extension.empty? ? output : output.rchop(extension)
      "#{stem}.temp#{extension}"
    end
  end

  class FFmpegSubtitlesConvertorPostProcessor < PostProcessor
    SUPPORTED_FORMATS = %w[ass lrc srt vtt]

    def key : String
      "FFmpegSubtitlesConvertor"
    end

    def run(info : Info) : Info
      target = @client.options.string?("convertsubtitles") || return info
      return info if target == "none"
      unless SUPPORTED_FORMATS.includes?(target)
        raise PostProcessingError.new("Unsupported subtitle conversion format #{target}")
      end

      subtitles = info.hash?("requested_subtitles") || return info
      subtitles.each do |language, value|
        subtitle = value.as_h
        source = subtitle["filepath"]?.try(&.as_s?)
        next unless source && File.exists?(source)
        extension = subtitle["ext"]?.try(&.as_s?) || Path.new(source).extension.lstrip('.')
        next if extension == target
        if extension.in?("json", "json3")
          @client.warning("Skipping conversion of #{language} JSON subtitles")
          next
        end

        destination = replace_extension(source, target)
        File.delete?(destination)
        format = target == "vtt" ? "webvtt" : target
        result = @client.process_runner.run(
          ffmpeg_path,
          ["-y", "-i", source, "-f", format, destination],
        )
        unless result.success?
          File.delete?(destination)
          detail = result.error.strip
          detail = "exit code #{result.exit_code}" if detail.empty?
          raise PostProcessingError.new("ffmpeg subtitle conversion failed: #{detail}")
        end
        unless File.exists?(destination)
          raise PostProcessingError.new("ffmpeg completed without creating converted subtitles")
        end

        File.delete?(source) unless source == destination
        converted = subtitle.dup
        converted["ext"] = JSON::Any.new(target)
        converted["filepath"] = JSON::Any.new(destination)
        converted["data"] = JSON::Any.new(File.read(destination))
        subtitles[language] = JSON::Any.new(converted)
      end
      info["requested_subtitles"] = JSON::Any.new(subtitles)
      info
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to convert subtitles: #{error.message}", cause: error)
    end

    private def ffmpeg_path : String
      location = @client.options.string?("ffmpeg_location")
      return "ffmpeg" unless location
      return location unless File.directory?(location)
      executable = {{ flag?(:win32) ? "ffmpeg.exe" : "ffmpeg" }}
      File.join(location, executable)
    end

    private def replace_extension(path : String, extension : String) : String
      current = Path.new(path).extension
      stem = current.empty? ? path : path.rchop(current)
      "#{stem}.#{extension}"
    end
  end

  class FFmpegThumbnailsConvertorPostProcessor < PostProcessor
    SUPPORTED_FORMATS = %w[jpg png webp]

    def key : String
      "FFmpegThumbnailsConvertor"
    end

    def run(info : Info) : Info
      mapping = @client.options.string?("convertthumbnails") || return info
      return info if mapping == "none"
      thumbnails = info.array?("thumbnails") || return info

      thumbnails.each do |value|
        thumbnail = value.as_h
        source = thumbnail["filepath"]?.try(&.as_s?)
        next unless source && File.exists?(source)
        source_extension = Path.new(source).extension.lstrip('.').downcase
        source_extension = "jpg" if source_extension == "jpeg"
        target = resolve_mapping(source_extension, mapping)
        next unless target
        unless SUPPORTED_FORMATS.includes?(target)
          raise PostProcessingError.new("Unsupported thumbnail conversion format #{target}")
        end
        next if target == source_extension

        destination = replace_extension(source, target)
        File.delete?(destination)
        arguments = ["-y", "-i", source, "-frames:v", "1", "-update", "1"]
        arguments.concat(["-bsf:v", "mjpeg2jpeg"]) if target == "jpg"
        arguments << destination
        result = @client.process_runner.run(ffmpeg_path, arguments)
        unless result.success?
          File.delete?(destination)
          detail = result.error.strip
          detail = "exit code #{result.exit_code}" if detail.empty?
          raise PostProcessingError.new("ffmpeg thumbnail conversion failed: #{detail}")
        end
        unless File.exists?(destination)
          raise PostProcessingError.new("ffmpeg completed without creating converted thumbnail")
        end

        File.delete?(source) unless source == destination
        thumbnail["ext"] = JSON::Any.new(target)
        thumbnail["filepath"] = JSON::Any.new(destination)
      end
      info["thumbnails"] = JSON::Any.new(thumbnails)
      info
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to convert thumbnails: #{error.message}", cause: error)
    end

    private def resolve_mapping(source : String, mapping : String) : String?
      mapping.downcase.split('/').each do |rule|
        input, separator, output = rule.partition('>')
        if separator.empty?
          output = input
          input = ""
        end
        input = input.strip
        output = output.strip
        return output if input.empty? || input == source
      end
      nil
    end

    private def ffmpeg_path : String
      location = @client.options.string?("ffmpeg_location")
      return "ffmpeg" unless location
      return location unless File.directory?(location)
      executable = {{ flag?(:win32) ? "ffmpeg.exe" : "ffmpeg" }}
      File.join(location, executable)
    end

    private def replace_extension(path : String, extension : String) : String
      current = Path.new(path).extension
      stem = current.empty? ? path : path.rchop(current)
      "#{stem}.#{extension}"
    end
  end

  class FFmpegEmbedSubtitlePostProcessor < PostProcessor
    SUPPORTED_EXTENSIONS = %w[mp4 mov m4a webm mkv mka]

    def key : String
      "FFmpegEmbedSubtitle"
    end

    def run(info : Info) : Info
      extension = info.ext.downcase
      unless SUPPORTED_EXTENSIONS.includes?(extension)
        @client.info_log(
          "[FFmpegEmbedSubtitle] Subtitles can only be embedded in " \
          "#{SUPPORTED_EXTENSIONS.join(", ")} files",
        )
        return info
      end

      subtitles = info.hash?("requested_subtitles")
      unless subtitles && !subtitles.empty?
        @client.info_log("[FFmpegEmbedSubtitle] There aren't any subtitles to embed")
        return info
      end

      selected = [] of Tuple(String, String?, String)
      warned_webm = false
      warned_mp4_ass = false
      subtitles.each do |language, value|
        subtitle = value.as_h
        path = subtitle["filepath"]?.try(&.as_s?)
        unless path && File.exists?(path)
          @client.warning("Skipping embedding #{language} subtitle because the file is missing")
          next
        end

        subtitle_extension = (
          subtitle["ext"]?.try(&.as_s?) ||
          Path.new(path).extension.lstrip('.')
        ).downcase
        if subtitle_extension.in?("json", "json3")
          @client.warning("JSON subtitles cannot be embedded")
          next
        end
        if extension == "webm" && subtitle_extension != "vtt"
          unless warned_webm
            @client.warning("Only WebVTT subtitles can be embedded in webm files")
            warned_webm = true
          end
          next
        end
        if extension == "mp4" && subtitle_extension == "ass" && !warned_mp4_ass
          @client.warning("ASS subtitles cannot be properly embedded in mp4 files; expect issues")
          warned_mp4_ass = true
        end

        selected << {language, subtitle["name"]?.try(&.as_s?), path}
      end
      return info if selected.empty?

      filename = info.string?("filepath") ||
                 raise PostProcessingError.new("Subtitle embed input filename is missing")
      temporary = temporary_filename(filename)
      File.delete?(temporary)

      arguments = ["-y", "-i", filename] of String
      selected.each { |_, _, path| arguments.concat(["-i", path]) }
      arguments.concat(["-map", "0", "-dn", "-ignore_unknown", "-c", "copy", "-map", "-0:s"])
      arguments.concat(["-c:s", "mov_text"]) if extension.in?("mp4", "mov", "m4a")
      selected.each_with_index do |(language, name, _), index|
        arguments.concat(["-map", "#{index + 1}:0"])
        language_code = ISO639.short_to_long(language) || language
        arguments.concat(["-metadata:s:s:#{index}", "language=#{language_code}"])
        if name
          arguments.concat(["-metadata:s:s:#{index}", "handler_name=#{name}"])
          arguments.concat(["-metadata:s:s:#{index}", "title=#{name}"])
        end
      end
      arguments.concat(["-movflags", "+faststart", temporary])

      run_ffmpeg(arguments, temporary, "subtitle embedding")
      replace_media(temporary, filename)
      unless @client.options.bool?("writesubtitles") == true
        selected.each { |_, _, path| File.delete?(path) }
      end
      info
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to embed subtitles: #{error.message}", cause: error)
    end

    private def run_ffmpeg(arguments : Array(String), output : String, action : String)
      result = @client.process_runner.run(ffmpeg_path, arguments)
      unless result.success?
        File.delete?(output)
        detail = result.error.strip
        detail = "exit code #{result.exit_code}" if detail.empty?
        raise PostProcessingError.new("ffmpeg #{action} failed: #{detail}")
      end
      unless File.exists?(output)
        raise PostProcessingError.new("ffmpeg completed without creating embedded output")
      end
    end

    private def replace_media(temporary : String, filename : String)
      backup = "#{temporary}.original"
      File.delete?(backup)
      File.rename(filename, backup)
      begin
        File.rename(temporary, filename)
        File.delete?(backup)
      rescue error
        File.rename(backup, filename) if File.exists?(backup) && !File.exists?(filename)
        raise error
      end
    end

    private def ffmpeg_path : String
      location = @client.options.string?("ffmpeg_location")
      return "ffmpeg" unless location
      return location unless File.directory?(location)
      executable = {{ flag?(:win32) ? "ffmpeg.exe" : "ffmpeg" }}
      File.join(location, executable)
    end

    private def temporary_filename(output : String) : String
      extension = Path.new(output).extension
      stem = extension.empty? ? output : output.rchop(extension)
      "#{stem}.temp#{extension}"
    end
  end

  class EmbedThumbnailPostProcessor < PostProcessor
    SUPPORTED_EXTENSIONS    = %w[mp3 mkv mka m4a mp4 m4v mov flac ogg opus]
    DIRECT_IMAGE_EXTENSIONS = %w[jpg jpeg png]

    def key : String
      "EmbedThumbnail"
    end

    def run(info : Info) : Info
      filename = info.string?("filepath") ||
                 raise PostProcessingError.new("Thumbnail embed input filename is missing")
      extension = info.ext.downcase
      unless SUPPORTED_EXTENSIONS.includes?(extension)
        raise PostProcessingError.new(
          "Supported filetypes for thumbnail embedding are: #{SUPPORTED_EXTENSIONS.join(", ")}",
        )
      end

      thumbnail = info.array?("thumbnails").try do |thumbnails|
        thumbnails.reverse_each.find do |value|
          value.as_h["filepath"]?.try(&.as_s?)
        end
      end
      unless thumbnail
        @client.info_log("[EmbedThumbnail] There are no thumbnails on disk")
        return info
      end

      values = thumbnail.as_h
      original_thumbnail = values["filepath"].as_s
      unless File.exists?(original_thumbnail)
        @client.warning("Skipping embedding the thumbnail because the file is missing")
        return info
      end

      thumbnail_path = original_thumbnail
      converted_thumbnail = nil
      thumbnail_extension = Path.new(thumbnail_path).extension.lstrip('.').downcase
      if !extension.in?("mkv", "mka") && !DIRECT_IMAGE_EXTENSIONS.includes?(thumbnail_extension)
        thumbnail_path = convert_thumbnail(original_thumbnail, "png")
        converted_thumbnail = thumbnail_path
        thumbnail_extension = "png"
      end

      temporary = temporary_filename(filename)
      File.delete?(temporary)
      arguments = embed_arguments(
        filename,
        thumbnail_path,
        temporary,
        extension,
        thumbnail_extension,
        info,
      )
      run_ffmpeg(arguments, temporary)
      replace_media(temporary, filename)

      File.delete?(converted_thumbnail) if converted_thumbnail
      unless thumbnail_explicitly_requested?
        File.delete?(original_thumbnail)
      end
      info
    rescue error : PostProcessingError
      File.delete?(converted_thumbnail) if converted_thumbnail
      raise error
    rescue error
      File.delete?(converted_thumbnail) if converted_thumbnail
      raise PostProcessingError.new("Unable to embed thumbnail: #{error.message}", cause: error)
    end

    private def embed_arguments(
      filename : String,
      thumbnail : String,
      output : String,
      extension : String,
      thumbnail_extension : String,
      info : Info,
    ) : Array(String)
      case extension
      when "mp3"
        [
          "-y", "-i", filename, "-i", thumbnail,
          "-c", "copy", "-map", "0:0", "-map", "1:0",
          "-write_id3v1", "1", "-id3v2_version", "3",
          "-metadata:s:v", "title=Album cover",
          "-metadata:s:v", "comment=Cover (front)",
          "-movflags", "+faststart", output,
        ]
      when "mkv", "mka"
        mime = "image/#{thumbnail_extension == "jpg" ? "jpeg" : thumbnail_extension}"
        [
          "-y", "-i", filename, "-map", "0", "-dn", "-ignore_unknown", "-c", "copy",
          "-attach", thumbnail,
          "-metadata:s:t", "mimetype=#{mime}",
          "-metadata:s:t", "filename=cover.#{thumbnail_extension}",
          output,
        ]
      when "m4a", "mp4", "m4v", "mov"
        attached_index = extension == "m4a" || info.string?("vcodec") == "none" ? 0 : 1
        [
          "-y", "-i", filename, "-i", thumbnail,
          "-map", "0", "-map", "1:v:0", "-dn", "-ignore_unknown", "-c", "copy",
          "-disposition:v:#{attached_index}", "attached_pic",
          "-movflags", "+faststart", output,
        ]
      when "flac"
        [
          "-y", "-i", filename, "-i", thumbnail,
          "-map", "0:a?", "-map", "1:v:0", "-c", "copy",
          "-disposition:v:0", "attached_pic",
          output,
        ]
      when "ogg", "opus"
        picture = metadata_block_picture(thumbnail, thumbnail_extension)
        [
          "-y", "-i", filename,
          "-map", "0:a?", "-dn", "-ignore_unknown", "-c", "copy",
          "-metadata", "METADATA_BLOCK_PICTURE=#{picture}",
          output,
        ]
      else
        raise PostProcessingError.new("Unsupported thumbnail embed extension #{extension}")
      end
    end

    private def metadata_block_picture(thumbnail : String, extension : String) : String
      mime = extension.in?("jpg", "jpeg") ? "image/jpeg" : "image/#{extension}"
      image = File.read(thumbnail).to_slice.dup
      block = IO::Memory.new
      write_be32(block, 3)
      write_blob(block, mime.to_slice)
      write_blob(block, Bytes.empty)
      4.times { write_be32(block, 0) }
      write_blob(block, image)
      Base64.strict_encode(block.to_slice)
    end

    private def write_blob(output : IO, value : Bytes)
      write_be32(output, value.size)
      output.write(value)
    end

    private def write_be32(output : IO, value : Int)
      output.write_bytes(value.to_u32, IO::ByteFormat::BigEndian)
    end

    private def convert_thumbnail(source : String, extension : String) : String
      current = Path.new(source).extension
      stem = current.empty? ? source : source.rchop(current)
      destination = "#{stem}.temp.#{extension}"
      File.delete?(destination)
      arguments = [
        "-y", "-i", source, "-frames:v", "1", "-update", "1", destination,
      ]
      result = @client.process_runner.run(ffmpeg_path, arguments)
      unless result.success?
        File.delete?(destination)
        detail = result.error.strip
        detail = "exit code #{result.exit_code}" if detail.empty?
        raise PostProcessingError.new("ffmpeg thumbnail conversion failed: #{detail}")
      end
      unless File.exists?(destination)
        raise PostProcessingError.new("ffmpeg completed without creating converted thumbnail")
      end
      destination
    end

    private def run_ffmpeg(arguments : Array(String), output : String)
      result = @client.process_runner.run(ffmpeg_path, arguments)
      unless result.success?
        File.delete?(output)
        detail = result.error.strip
        detail = "exit code #{result.exit_code}" if detail.empty?
        raise PostProcessingError.new("ffmpeg thumbnail embedding failed: #{detail}")
      end
      unless File.exists?(output)
        raise PostProcessingError.new("ffmpeg completed without creating embedded output")
      end
    end

    private def thumbnail_explicitly_requested? : Bool
      value = @client.options["writethumbnail"]
      value.try(&.as_bool?) == true || value.try(&.as_s?) == "all"
    end

    private def replace_media(temporary : String, filename : String)
      backup = "#{temporary}.original"
      File.delete?(backup)
      File.rename(filename, backup)
      begin
        File.rename(temporary, filename)
        File.delete?(backup)
      rescue error
        File.rename(backup, filename) if File.exists?(backup) && !File.exists?(filename)
        raise error
      end
    end

    private def ffmpeg_path : String
      location = @client.options.string?("ffmpeg_location")
      return "ffmpeg" unless location
      return location unless File.directory?(location)
      executable = {{ flag?(:win32) ? "ffmpeg.exe" : "ffmpeg" }}
      File.join(location, executable)
    end

    private def temporary_filename(output : String) : String
      extension = Path.new(output).extension
      stem = extension.empty? ? output : output.rchop(extension)
      "#{stem}.temp#{extension}"
    end
  end

  abstract class FFmpegFixupPostProcessor < PostProcessor
    def run(info : Info) : Info
      filename = info.string?("filepath") ||
                 raise PostProcessingError.new("Fixup input filename is missing")
      temporary = temporary_filename(filename)
      File.delete?(temporary)
      arguments = ["-y", "-i", filename]
      arguments.concat(fixup_arguments(info))
      arguments.concat(["-movflags", "+faststart", temporary])

      result = @client.process_runner.run(ffmpeg_path, arguments)
      unless result.success?
        File.delete?(temporary)
        detail = result.error.strip
        detail = "exit code #{result.exit_code}" if detail.empty?
        raise PostProcessingError.new("ffmpeg #{description.downcase} failed: #{detail}")
      end
      unless File.exists?(temporary)
        raise PostProcessingError.new("ffmpeg completed without creating fixed output")
      end

      replace_media(temporary, filename)
      info
    rescue error : PostProcessingError
      raise error
    rescue error
      raise PostProcessingError.new("Unable to #{description.downcase}: #{error.message}", cause: error)
    end

    abstract def description : String
    protected abstract def fixup_arguments(info : Info) : Array(String)

    protected def stream_copy_arguments : Array(String)
      ["-map", "0", "-dn", "-ignore_unknown", "-c", "copy"]
    end

    private def replace_media(temporary : String, filename : String)
      backup = "#{temporary}.original"
      File.delete?(backup)
      File.rename(filename, backup)
      begin
        File.rename(temporary, filename)
        File.delete?(backup)
      rescue error
        File.rename(backup, filename) if File.exists?(backup) && !File.exists?(filename)
        raise error
      end
    end

    private def ffmpeg_path : String
      location = @client.options.string?("ffmpeg_location")
      return "ffmpeg" unless location
      return location unless File.directory?(location)
      executable = {{ flag?(:win32) ? "ffmpeg.exe" : "ffmpeg" }}
      File.join(location, executable)
    end

    private def temporary_filename(output : String) : String
      extension = Path.new(output).extension
      stem = extension.empty? ? output : output.rchop(extension)
      "#{stem}.temp#{extension}"
    end
  end

  class FFmpegFixupStretchedPostProcessor < FFmpegFixupPostProcessor
    def key : String
      "FFmpegFixupStretched"
    end

    def description : String
      "Fixing aspect ratio"
    end

    protected def fixup_arguments(info : Info) : Array(String)
      ratio = info.float?("stretched_ratio") ||
              raise PostProcessingError.new("Stretched aspect ratio is missing")
      stream_copy_arguments + ["-aspect", ratio.to_s]
    end
  end

  class FFmpegFixupM4aPostProcessor < FFmpegFixupPostProcessor
    def key : String
      "FFmpegFixupM4a"
    end

    def description : String
      "Correcting M4A container"
    end

    protected def fixup_arguments(info : Info) : Array(String)
      stream_copy_arguments + ["-f", "mp4"]
    end
  end

  class FFmpegFixupM3u8PostProcessor < FFmpegFixupPostProcessor
    def key : String
      "FFmpegFixupM3u8"
    end

    def description : String
      "Fixing MPEG-TS in MP4 container"
    end

    protected def fixup_arguments(info : Info) : Array(String)
      arguments = stream_copy_arguments + ["-f", "mp4"]
      codec = info.string?("acodec").try(&.downcase)
      if codec && (codec.starts_with?("aac") || codec.starts_with?("mp4a"))
        arguments.concat(["-bsf:a", "aac_adtstoasc"])
      end
      arguments
    end
  end

  class FFmpegFixupTimestampPostProcessor < FFmpegFixupPostProcessor
    def key : String
      "FFmpegFixupTimestamp"
    end

    def description : String
      "Fixing frame timestamp"
    end

    protected def fixup_arguments(info : Info) : Array(String)
      [
        "-c", "copy", "-bsf", "setts=ts=TS-STARTPTS",
        "-map", "0", "-dn", "-ignore_unknown", "-ss", "0.001",
      ]
    end
  end

  class FFmpegFixupDurationPostProcessor < FFmpegFixupPostProcessor
    def key : String
      "FFmpegFixupDuration"
    end

    def description : String
      "Fixing video duration"
    end

    protected def fixup_arguments(info : Info) : Array(String)
      stream_copy_arguments
    end
  end

  class FFmpegFixupDuplicateMoovPostProcessor < FFmpegFixupPostProcessor
    def key : String
      "FFmpegFixupDuplicateMoov"
    end

    def description : String
      "Fixing duplicate MOOV atoms"
    end

    protected def fixup_arguments(info : Info) : Array(String)
      stream_copy_arguments
    end
  end
end
