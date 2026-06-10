require "./spec_helper"

private class EmbeddingFixtureExtractor < CrDlp::Extractor
  def initialize(client : CrDlp::Client, @thumbnail_url : String? = nil)
    super(client)
  end

  def key : String
    "EmbeddingFixture"
  end

  def name : String
    "embedding-fixture"
  end

  def suitable?(url : String) : Bool
    url == "embedding:fixture"
  end

  def extract(url : String) : CrDlp::Info
    info = base_info("embedding", "embedding", url)
    info["url"] = "fixture://embedding"
    info["protocol"] = "fixture"
    info["ext"] = "mp4"
    info["vcodec"] = "mpeg4"
    info["fixture_data"] = "ORIGINAL MEDIA"
    info["subtitles"] = JSON::Any.new({
      "en" => JSON::Any.new([
        JSON::Any.new({
          "ext"  => JSON::Any.new("vtt"),
          "name" => JSON::Any.new("English"),
          "data" => JSON::Any.new("WEBVTT\n\n00:00.000 --> 00:01.000\nEmbedded\n"),
        }),
      ]),
    })
    if thumbnail_url = @thumbnail_url
      info["thumbnail"] = thumbnail_url
      info["thumbnails"] = JSON::Any.new([
        JSON::Any.new({
          "url" => JSON::Any.new(thumbnail_url),
          "ext" => JSON::Any.new("png"),
        }),
      ])
    end
    info
  end
end

private class EmbeddingProcessRunner < CrDlp::ProcessRunner
  getter calls = [] of Tuple(String, Array(String))

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    @calls << {command, arguments.dup}
    File.write(arguments.last, "EMBEDDED MEDIA")
    CrDlp::ProcessResult.new(0, "", "")
  end
end

private class FailingEmbeddingProcessRunner < CrDlp::ProcessRunner
  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    CrDlp::ProcessResult.new(1, "", "intentional failure")
  end
end

private class ConversionThenFailureRunner < CrDlp::ProcessRunner
  @calls = 0

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    @calls += 1
    if @calls == 1
      File.write(arguments.last, "CONVERTED")
      CrDlp::ProcessResult.new(0, "", "")
    else
      CrDlp::ProcessResult.new(1, "", "embed failed")
    end
  end
end

private def embedding_client(
  options : CrDlp::ParsedOptions,
  runner : CrDlp::ProcessRunner,
  thumbnail_url : String? = nil,
) : CrDlp::Client
  client = CrDlp::Client.new(options, process_runner: runner)
  client.extractor_registry.prepend("EmbeddingFixture", "embedding-fixture") do |instance|
    EmbeddingFixtureExtractor.new(instance, thumbnail_url)
  end
  client
end

private def embedding_info(
  media : String,
  extension : String,
  subtitles : Hash(String, JSON::Any)? = nil,
  thumbnails : Array(JSON::Any)? = nil,
) : CrDlp::Info
  values = {
    "id"       => JSON::Any.new("embedding"),
    "title"    => JSON::Any.new("embedding"),
    "ext"      => JSON::Any.new(extension),
    "filepath" => JSON::Any.new(media),
  }
  values["requested_subtitles"] = JSON::Any.new(subtitles) if subtitles
  values["thumbnails"] = JSON::Any.new(thumbnails) if thumbnails
  CrDlp::Info.new(values)
end

describe CrDlp::FFmpegEmbedSubtitlePostProcessor do
  it "implicitly writes, embeds, and removes subtitles while publishing hooks" do
    directory = File.join(Dir.tempdir, "cr-dlp-embed-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      runner = EmbeddingProcessRunner.new
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
        }),
        "embedsubtitles" => JSON::Any.new(true),
      })
      client = embedding_client(options, runner)
      events = [] of String
      client.add_postprocessor_hook do |event|
        events << "#{event["postprocessor"].as_s}:#{event["status"].as_s}"
      end

      info = client.extract_info("embedding:fixture")
      media = File.join(directory, "embedding.mp4")
      subtitle = File.join(directory, "embedding.en.vtt")
      File.read(media).should eq("EMBEDDED MEDIA")
      File.exists?(subtitle).should be_false
      arguments = runner.calls.first[1]
      arguments.should contain("-c:s")
      arguments.should contain("mov_text")
      arguments.should contain("language=eng")
      arguments.should contain("handler_name=English")
      info.hash?("requested_subtitles").not_nil!.keys.should eq(["en"])
      events.should contain("FFmpegEmbedSubtitle:started")
      events.should contain("FFmpegEmbedSubtitle:finished")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "retains explicitly requested subtitle sidecars" do
    directory = File.join(Dir.tempdir, "cr-dlp-embed-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
        }),
        "embedsubtitles" => JSON::Any.new(true),
        "writesubtitles" => JSON::Any.new(true),
      })

      embedding_client(options, EmbeddingProcessRunner.new)
        .extract_info("embedding:fixture")
      File.read(File.join(directory, "embedding.en.vtt")).should contain("Embedded")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "preserves the original media and sidecar when ffmpeg fails" do
    directory = File.join(Dir.tempdir, "cr-dlp-embed-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      media = File.join(directory, "video.mp4")
      subtitle = File.join(directory, "video.en.vtt")
      File.write(media, "ORIGINAL")
      File.write(subtitle, "WEBVTT")
      info = embedding_info(media, "mp4", {
        "en" => JSON::Any.new({
          "ext"      => JSON::Any.new("vtt"),
          "filepath" => JSON::Any.new(subtitle),
        }),
      })
      client = CrDlp::Client.new(
        CrDlp::ParsedOptions.new({"embedsubtitles" => JSON::Any.new(true)}),
        process_runner: FailingEmbeddingProcessRunner.new,
      )

      expect_raises(CrDlp::PostProcessingError, /intentional failure/) do
        CrDlp::FFmpegEmbedSubtitlePostProcessor.new(client).run(info)
      end
      File.read(media).should eq("ORIGINAL")
      File.exists?(subtitle).should be_true
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "embeds a real WebVTT stream with language metadata" do
    ffmpeg = Process.find_executable("ffmpeg")
    ffprobe = Process.find_executable("ffprobe")
    pending!("ffmpeg and ffprobe are required") unless ffmpeg && ffprobe

    directory = File.join(Dir.tempdir, "cr-dlp-embed-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      media = File.join(directory, "video.mp4")
      subtitle = File.join(directory, "video.en.vtt")
      Process.run(
        ffmpeg,
        [
          "-loglevel", "error", "-f", "lavfi", "-i",
          "color=c=black:s=16x16:d=1", "-c:v", "mpeg4", media,
        ],
      ).success?.should be_true
      File.write(subtitle, "WEBVTT\n\n00:00.000 --> 00:00.800\nReal subtitle\n")
      info = embedding_info(media, "mp4", {
        "en" => JSON::Any.new({
          "ext"      => JSON::Any.new("vtt"),
          "filepath" => JSON::Any.new(subtitle),
        }),
      })
      options = CrDlp::ParsedOptions.new({
        "embedsubtitles"  => JSON::Any.new(true),
        "ffmpeg_location" => JSON::Any.new(ffmpeg),
      })

      CrDlp::FFmpegEmbedSubtitlePostProcessor.new(
        CrDlp::Client.new(options),
      ).run(info)
      output = IO::Memory.new
      Process.run(
        ffprobe,
        [
          "-v", "error", "-select_streams", "s",
          "-show_entries", "stream=codec_name:stream_tags=language",
          "-of", "json", media,
        ],
        output: output,
      ).success?.should be_true
      streams = JSON.parse(output.to_s)["streams"].as_a
      streams.size.should eq(1)
      streams.first["codec_name"].as_s.should eq("mov_text")
      streams.first["tags"]["language"].as_s.should eq("eng")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

describe CrDlp::EmbedThumbnailPostProcessor do
  it "implicitly downloads, embeds, and removes a thumbnail while publishing hooks" do
    server = HTTP::Server.new do |context|
      context.response.content_type = "image/png"
      context.response.print("PNG")
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    directory = File.join(Dir.tempdir, "cr-dlp-embed-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      runner = EmbeddingProcessRunner.new
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
        }),
        "embedthumbnail" => JSON::Any.new(true),
      })
      client = embedding_client(
        options,
        runner,
        "http://127.0.0.1:#{address.port}/cover.png",
      )
      events = [] of String
      client.add_postprocessor_hook do |event|
        events << "#{event["postprocessor"].as_s}:#{event["status"].as_s}"
      end

      client.extract_info("embedding:fixture")
      File.read(File.join(directory, "embedding.mp4")).should eq("EMBEDDED MEDIA")
      File.exists?(File.join(directory, "embedding.png")).should be_false
      arguments = runner.calls.first[1]
      arguments.should contain("-disposition:v:1")
      arguments.should contain("attached_pic")
      events.should contain("EmbedThumbnail:started")
      events.should contain("EmbedThumbnail:finished")
    ensure
      server.close
      FileUtils.rm_rf(directory)
    end
  end

  it "retains explicitly requested thumbnail sidecars" do
    directory = File.join(Dir.tempdir, "cr-dlp-embed-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      media = File.join(directory, "audio.m4a")
      thumbnail = File.join(directory, "cover.jpg")
      File.write(media, "AUDIO")
      File.write(thumbnail, "JPEG")
      info = embedding_info(media, "m4a", thumbnails: [
        JSON::Any.new({
          "ext"      => JSON::Any.new("jpg"),
          "filepath" => JSON::Any.new(thumbnail),
        }),
      ])
      options = CrDlp::ParsedOptions.new({
        "embedthumbnail" => JSON::Any.new(true),
        "writethumbnail" => JSON::Any.new(true),
      })

      CrDlp::EmbedThumbnailPostProcessor.new(
        CrDlp::Client.new(options, process_runner: EmbeddingProcessRunner.new),
      ).run(info)
      File.exists?(thumbnail).should be_true
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "cleans converted intermediates and preserves inputs when embedding fails" do
    directory = File.join(Dir.tempdir, "cr-dlp-embed-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      media = File.join(directory, "audio.m4a")
      thumbnail = File.join(directory, "cover.webp")
      converted = File.join(directory, "cover.temp.png")
      File.write(media, "AUDIO")
      File.write(thumbnail, "WEBP")
      info = embedding_info(media, "m4a", thumbnails: [
        JSON::Any.new({
          "ext"      => JSON::Any.new("webp"),
          "filepath" => JSON::Any.new(thumbnail),
        }),
      ])
      info["vcodec"] = "none"
      client = CrDlp::Client.new(
        CrDlp::ParsedOptions.new({"embedthumbnail" => JSON::Any.new(true)}),
        process_runner: ConversionThenFailureRunner.new,
      )

      expect_raises(CrDlp::PostProcessingError, /embed failed/) do
        CrDlp::EmbedThumbnailPostProcessor.new(client).run(info)
      end
      File.read(media).should eq("AUDIO")
      File.read(thumbnail).should eq("WEBP")
      File.exists?(converted).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "writes Ogg cover art as a metadata picture block" do
    directory = File.join(Dir.tempdir, "cr-dlp-embed-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      media = File.join(directory, "audio.opus")
      thumbnail = File.join(directory, "cover.jpg")
      File.write(media, "AUDIO")
      File.write(thumbnail, "JPEG")
      info = embedding_info(media, "opus", thumbnails: [
        JSON::Any.new({
          "ext"      => JSON::Any.new("jpg"),
          "filepath" => JSON::Any.new(thumbnail),
        }),
      ])
      runner = EmbeddingProcessRunner.new

      CrDlp::EmbedThumbnailPostProcessor.new(
        CrDlp::Client.new(process_runner: runner),
      ).run(info)
      metadata = runner.calls.first[1].find(&.starts_with?("METADATA_BLOCK_PICTURE="))
      metadata.should_not be_nil
      picture = Base64.decode(metadata.not_nil!.partition('=')[2])
      IO::ByteFormat::BigEndian.decode(UInt32, picture[0, 4]).should eq(3)
      String.new(picture[8, 10]).should eq("image/jpeg")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "embeds real attached cover art in an M4A file" do
    ffmpeg = Process.find_executable("ffmpeg")
    ffprobe = Process.find_executable("ffprobe")
    pending!("ffmpeg and ffprobe are required") unless ffmpeg && ffprobe

    directory = File.join(Dir.tempdir, "cr-dlp-embed-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      media = File.join(directory, "audio.m4a")
      thumbnail = File.join(directory, "cover.png")
      Process.run(
        ffmpeg,
        [
          "-loglevel", "error", "-f", "lavfi", "-i",
          "sine=frequency=1000:duration=1", "-c:a", "aac", media,
        ],
      ).success?.should be_true
      Process.run(
        ffmpeg,
        [
          "-loglevel", "error", "-f", "lavfi", "-i",
          "color=c=red:s=16x16", "-frames:v", "1", "-update", "1", thumbnail,
        ],
      ).success?.should be_true
      info = embedding_info(media, "m4a", thumbnails: [
        JSON::Any.new({
          "ext"      => JSON::Any.new("png"),
          "filepath" => JSON::Any.new(thumbnail),
        }),
      ])
      info["vcodec"] = "none"
      options = CrDlp::ParsedOptions.new({
        "embedthumbnail"  => JSON::Any.new(true),
        "ffmpeg_location" => JSON::Any.new(ffmpeg),
      })

      CrDlp::EmbedThumbnailPostProcessor.new(
        CrDlp::Client.new(options),
      ).run(info)
      output = IO::Memory.new
      Process.run(
        ffprobe,
        [
          "-v", "error", "-select_streams", "v",
          "-show_entries", "stream=codec_name:stream_disposition=attached_pic",
          "-of", "json", media,
        ],
        output: output,
      ).success?.should be_true
      stream = JSON.parse(output.to_s)["streams"].as_a.first
      stream["codec_name"].as_s.should eq("png")
      stream["disposition"]["attached_pic"].as_i.should eq(1)
      File.exists?(thumbnail).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "embeds real attached cover art in an Opus file" do
    ffmpeg = Process.find_executable("ffmpeg")
    ffprobe = Process.find_executable("ffprobe")
    pending!("ffmpeg and ffprobe are required") unless ffmpeg && ffprobe

    directory = File.join(Dir.tempdir, "cr-dlp-embed-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      media = File.join(directory, "audio.opus")
      thumbnail = File.join(directory, "cover.png")
      Process.run(
        ffmpeg,
        [
          "-loglevel", "error", "-f", "lavfi", "-i",
          "sine=frequency=1000:duration=0.2", "-c:a", "libopus", media,
        ],
      ).success?.should be_true
      Process.run(
        ffmpeg,
        [
          "-loglevel", "error", "-f", "lavfi", "-i",
          "color=c=blue:s=16x16", "-frames:v", "1", "-update", "1", thumbnail,
        ],
      ).success?.should be_true
      info = embedding_info(media, "opus", thumbnails: [
        JSON::Any.new({
          "ext"      => JSON::Any.new("png"),
          "filepath" => JSON::Any.new(thumbnail),
        }),
      ])
      info["vcodec"] = "none"
      options = CrDlp::ParsedOptions.new({
        "embedthumbnail"  => JSON::Any.new(true),
        "ffmpeg_location" => JSON::Any.new(ffmpeg),
      })

      CrDlp::EmbedThumbnailPostProcessor.new(
        CrDlp::Client.new(options),
      ).run(info)
      output = IO::Memory.new
      Process.run(
        ffprobe,
        [
          "-v", "error", "-select_streams", "v",
          "-show_entries", "stream=codec_name:stream_disposition=attached_pic",
          "-of", "json", media,
        ],
        output: output,
      ).success?.should be_true
      stream = JSON.parse(output.to_s)["streams"].as_a.first
      stream["codec_name"].as_s.should eq("png")
      stream["disposition"]["attached_pic"].as_i.should eq(1)
      File.exists?(thumbnail).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
