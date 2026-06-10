require "./spec_helper"

private class SubtitleFixtureExtractor < CrDlp::Extractor
  def initialize(client : CrDlp::Client, @subtitle_url : String? = nil)
    super(client)
  end

  def key : String
    "SubtitleFixture"
  end

  def name : String
    "subtitle-fixture"
  end

  def suitable?(url : String) : Bool
    url == "subtitle:fixture"
  end

  def extract(url : String) : CrDlp::Info
    info = base_info("subtitles", "subtitles", url)
    info["url"] = "fixture://subtitles"
    info["protocol"] = "fixture"
    info["ext"] = "mp4"
    info["fixture_data"] = "VIDEO"
    english = [
      JSON::Any.new({
        "ext"  => JSON::Any.new("vtt"),
        "data" => JSON::Any.new("WEBVTT\n\n00:00.000 --> 00:01.000\nEnglish VTT\n"),
      }),
      JSON::Any.new({
        "ext"  => JSON::Any.new("srt"),
        "data" => JSON::Any.new("1\n00:00:00,000 --> 00:00:01,000\nEnglish SRT\n"),
      }),
    ]
    french = [
      JSON::Any.new({
        "ext"  => JSON::Any.new("vtt"),
        "data" => JSON::Any.new("WEBVTT\n\nFrench\n"),
      }),
    ]
    info["subtitles"] = JSON::Any.new({
      "en" => JSON::Any.new(english),
      "fr" => JSON::Any.new(french),
    })

    automatic = {
      "en" => JSON::Any.new([
        JSON::Any.new({
          "ext"  => JSON::Any.new("vtt"),
          "data" => JSON::Any.new("AUTOMATIC ENGLISH"),
        }),
      ]),
    }
    if subtitle_url = @subtitle_url
      automatic["es"] = JSON::Any.new([
        JSON::Any.new({
          "url" => JSON::Any.new(subtitle_url),
          "ext" => JSON::Any.new("vtt"),
        }),
      ])
    else
      automatic["es"] = JSON::Any.new([
        JSON::Any.new({
          "ext"  => JSON::Any.new("vtt"),
          "data" => JSON::Any.new("WEBVTT\n\nSpanish\n"),
        }),
      ])
    end
    info["automatic_captions"] = JSON::Any.new(automatic)
    info
  end
end

private class SubtitleProcessRunner < CrDlp::ProcessRunner
  getter calls = [] of Tuple(String, Array(String))

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    @calls << {command, arguments.dup}
    File.write(arguments.last, "1\n00:00:00,000 --> 00:00:01,000\nConverted\n")
    CrDlp::ProcessResult.new(0, "", "")
  end
end

private def subtitle_client(
  options : CrDlp::ParsedOptions,
  subtitle_url : String? = nil,
  runner : CrDlp::ProcessRunner = CrDlp::SystemProcessRunner.new,
) : CrDlp::Client
  client = CrDlp::Client.new(options, process_runner: runner)
  client.extractor_registry.prepend("SubtitleFixture", "subtitle-fixture") do |instance|
    SubtitleFixtureExtractor.new(instance, subtitle_url)
  end
  client
end

describe CrDlp::SubtitleSelector do
  it "selects regex languages, exclusions, formats, and normal subtitle precedence" do
    options = CrDlp::ParsedOptions.new({
      "writesubtitles"    => JSON::Any.new(true),
      "writeautomaticsub" => JSON::Any.new(true),
      "subtitleslangs"    => JSON::Any.new([
        JSON::Any.new("all"),
        JSON::Any.new("-fr"),
      ]),
      "subtitlesformat" => JSON::Any.new("srt/vtt/best"),
    })
    info = subtitle_client(options).extract_info("subtitle:fixture", download: false)
    requested = info.hash?("requested_subtitles").not_nil!

    requested.keys.should eq(["en", "es"])
    requested["en"].as_h["ext"].as_s.should eq("srt")
    requested["en"].as_h["data"].as_s.should contain("English SRT")
    requested["es"].as_h["ext"].as_s.should eq("vtt")
  end

  it "defaults to the first English normal subtitle and best format" do
    options = CrDlp::ParsedOptions.new({
      "writesubtitles" => JSON::Any.new(true),
    })
    info = subtitle_client(options).extract_info("subtitle:fixture", download: false)
    requested = info.hash?("requested_subtitles").not_nil!

    requested.keys.should eq(["en"])
    requested["en"].as_h["ext"].as_s.should eq("srt")
  end

  it "selects normal subtitles implicitly for embedding" do
    options = CrDlp::ParsedOptions.new({
      "embedsubtitles" => JSON::Any.new(true),
    })
    info = subtitle_client(options).extract_info("subtitle:fixture", download: false)

    requested = info.hash?("requested_subtitles").not_nil!
    requested.keys.should eq(["en"])
    requested["en"].as_h["ext"].as_s.should eq("srt")
  end

  it "supports case-insensitive full-match language regular expressions" do
    options = CrDlp::ParsedOptions.new({
      "writesubtitles" => JSON::Any.new(true),
      "subtitleslangs" => JSON::Any.new([JSON::Any.new("E.*")]),
    })
    requested = subtitle_client(options)
      .extract_info("subtitle:fixture", download: false)
      .hash?("requested_subtitles").not_nil!

    requested.keys.should eq(["en"])
  end

  it "rejects malformed subtitle language regular expressions" do
    options = CrDlp::ParsedOptions.new({
      "writesubtitles" => JSON::Any.new(true),
      "subtitleslangs" => JSON::Any.new([JSON::Any.new("[")]),
    })
    expect_raises(CrDlp::UsageError, /Invalid subtitle language regular expression/) do
      subtitle_client(options).extract_info("subtitle:fixture", download: false)
    end
  end
end

describe "subtitle downloads" do
  it "writes inline and HTTP subtitles with subtitle-specific templates and paths" do
    server = HTTP::Server.new do |context|
      context.response.content_type = "text/vtt"
      context.response.print("WEBVTT\n\n00:00.000 --> 00:01.000\nSpanish HTTP\n")
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    directory = File.join(Dir.tempdir, "cr-dlp-subs-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default"  => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
          "subtitle" => JSON::Any.new("%(id)s.%(ext)s"),
        }),
        "paths" => JSON::Any.new({
          "subtitle" => JSON::Any.new(File.join(directory, "captions")),
        }),
        "writesubtitles"    => JSON::Any.new(true),
        "writeautomaticsub" => JSON::Any.new(true),
        "subtitleslangs"    => JSON::Any.new([
          JSON::Any.new("en"),
          JSON::Any.new("es"),
        ]),
        "subtitlesformat" => JSON::Any.new("vtt"),
      })
      info = subtitle_client(
        options,
        "http://127.0.0.1:#{address.port}/spanish.vtt",
      ).extract_info("subtitle:fixture")

      File.read(File.join(directory, "subtitles.mp4")).should eq("VIDEO")
      File.read(File.join(directory, "captions", "subtitles.en.vtt")).should contain("English VTT")
      File.read(File.join(directory, "captions", "subtitles.es.vtt")).should contain("Spanish HTTP")
      requested = info.hash?("requested_subtitles").not_nil!
      requested["es"].as_h["filepath"].as_s.should end_with("subtitles.es.vtt")
    ensure
      server.close
      FileUtils.rm_rf(directory)
    end
  end

  it "downloads segmented HLS subtitle renditions through the native downloader" do
    server = HTTP::Server.new do |context|
      case context.request.path
      when "/master.m3u8"
        context.response.print <<-'M3U8'
          #EXTM3U
          #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="captions.m3u8"
          #EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=320x180,SUBTITLES="subs"
          video.m3u8
          M3U8
      when "/captions.m3u8"
        context.response.print("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\ncaption.vtt\n#EXT-X-ENDLIST\n")
      when "/caption.vtt"
        context.response.print("WEBVTT\n\n00:00.000 --> 00:01.000\nSegmented subtitle\n")
      when "/video.m3u8"
        context.response.print("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nvideo.ts\n#EXT-X-ENDLIST\n")
      when "/video.ts"
        context.response.print("VIDEO")
      else
        context.response.status = HTTP::Status::NOT_FOUND
      end
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    directory = File.join(Dir.tempdir, "cr-dlp-subs-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
        }),
        "writesubtitles" => JSON::Any.new(true),
        "subtitleslangs" => JSON::Any.new([JSON::Any.new("en")]),
        "skip_download"  => JSON::Any.new(true),
      })
      client = CrDlp::Client.new(options)

      client.download(["http://127.0.0.1:#{address.port}/master.m3u8"]).should eq(0)
      File.read(File.join(directory, "master.en.vtt")).should contain("Segmented subtitle")
      File.exists?(File.join(directory, "master.mp4")).should be_false
    ensure
      server.close
      FileUtils.rm_rf(directory)
    end
  end

  it "writes subtitle sidecars while --skip-download omits the media file" do
    directory = File.join(Dir.tempdir, "cr-dlp-subs-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
        }),
        "writesubtitles"  => JSON::Any.new(true),
        "subtitleslangs"  => JSON::Any.new([JSON::Any.new("en")]),
        "subtitlesformat" => JSON::Any.new("vtt"),
        "skip_download"   => JSON::Any.new(true),
      })
      client = subtitle_client(options)

      client.download(["subtitle:fixture"]).should eq(0)
      File.exists?(File.join(directory, "subtitles.mp4")).should be_false
      File.read(File.join(directory, "subtitles.en.vtt")).should contain("English VTT")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "converts subtitles through ffmpeg and publishes postprocessor hooks" do
    directory = File.join(Dir.tempdir, "cr-dlp-subs-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      runner = SubtitleProcessRunner.new
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
        }),
        "writesubtitles"   => JSON::Any.new(true),
        "subtitleslangs"   => JSON::Any.new([JSON::Any.new("en")]),
        "subtitlesformat"  => JSON::Any.new("vtt"),
        "convertsubtitles" => JSON::Any.new("srt"),
      })
      client = subtitle_client(options, runner: runner)
      events = [] of String
      client.add_postprocessor_hook do |event|
        events << "#{event["postprocessor"].as_s}:#{event["status"].as_s}"
      end
      info = client.extract_info("subtitle:fixture")

      File.exists?(File.join(directory, "subtitles.en.vtt")).should be_false
      File.read(File.join(directory, "subtitles.en.srt")).should contain("Converted")
      runner.calls.first[1][-2, 2].should eq(["srt", File.join(directory, "subtitles.en.srt")])
      subtitle = info.hash?("requested_subtitles").not_nil!["en"].as_h
      subtitle["ext"].as_s.should eq("srt")
      subtitle["filepath"].as_s.should end_with("subtitles.en.srt")
      events.should contain("FFmpegSubtitlesConvertor:started")
      events.should contain("FFmpegSubtitlesConvertor:finished")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "performs a real VTT-to-SRT conversion when ffmpeg is available" do
    ffmpeg = Process.find_executable("ffmpeg")
    pending!("ffmpeg is not available") unless ffmpeg

    directory = File.join(Dir.tempdir, "cr-dlp-subs-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "captions.en.vtt")
      File.write(source, "WEBVTT\n\n00:00.000 --> 00:01.000\nConverted by ffmpeg\n")
      info = CrDlp::Info.new({
        "requested_subtitles" => JSON::Any.new({
          "en" => JSON::Any.new({
            "ext"      => JSON::Any.new("vtt"),
            "filepath" => JSON::Any.new(source),
          }),
        }),
      })
      options = CrDlp::ParsedOptions.new({
        "convertsubtitles" => JSON::Any.new("srt"),
        "ffmpeg_location"  => JSON::Any.new(ffmpeg),
      })
      client = CrDlp::Client.new(options)

      CrDlp::FFmpegSubtitlesConvertorPostProcessor.new(client).run(info)
      destination = File.join(directory, "captions.en.srt")
      File.read(destination).should contain("Converted by ffmpeg")
      File.exists?(source).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
