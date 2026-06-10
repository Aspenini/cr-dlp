require "./spec_helper"

private class ThumbnailFixtureExtractor < CrDlp::Extractor
  def initialize(client : CrDlp::Client, @base_url : String)
    super(client)
  end

  def key : String
    "ThumbnailFixture"
  end

  def name : String
    "thumbnail-fixture"
  end

  def suitable?(url : String) : Bool
    url == "thumbnail:fixture"
  end

  def extract(url : String) : CrDlp::Info
    info = base_info("thumbnail", "thumbnail", url)
    info["url"] = "fixture://thumbnail"
    info["protocol"] = "fixture"
    info["ext"] = "mp4"
    info["fixture_data"] = "VIDEO"
    info["thumbnail"] = "#{@base_url}/best.jpg"
    info["thumbnails"] = JSON::Any.new([
      JSON::Any.new({
        "id"     => JSON::Any.new("small"),
        "url"    => JSON::Any.new("#{@base_url}/small.png"),
        "ext"    => JSON::Any.new("png"),
        "width"  => JSON::Any.new(120_i64),
        "height" => JSON::Any.new(90_i64),
      }),
      JSON::Any.new({
        "id"     => JSON::Any.new("large/cover"),
        "url"    => JSON::Any.new("#{@base_url}/best.jpg"),
        "ext"    => JSON::Any.new("jpg"),
        "width"  => JSON::Any.new(1280_i64),
        "height" => JSON::Any.new(720_i64),
      }),
    ])
    info
  end
end

private class ThumbnailProcessRunner < CrDlp::ProcessRunner
  getter calls = [] of Tuple(String, Array(String))

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    @calls << {command, arguments.dup}
    File.write(arguments.last, "CONVERTED")
    CrDlp::ProcessResult.new(0, "", "")
  end
end

private def thumbnail_client(
  options : CrDlp::ParsedOptions,
  base_url : String,
  runner : CrDlp::ProcessRunner = CrDlp::SystemProcessRunner.new,
) : CrDlp::Client
  client = CrDlp::Client.new(options, process_runner: runner)
  client.extractor_registry.prepend("ThumbnailFixture", "thumbnail-fixture") do |instance|
    ThumbnailFixtureExtractor.new(instance, base_url)
  end
  client
end

private def with_thumbnail_server(best_status = HTTP::Status::OK, &block : String ->)
  server = HTTP::Server.new do |context|
    case context.request.path
    when "/small.png"
      context.response.content_type = "image/png"
      context.response.print("SMALL")
    when "/best.jpg"
      context.response.status = best_status
      if best_status.success?
        context.response.content_type = "image/jpeg"
        context.response.print("BEST")
      end
    else
      context.response.status = HTTP::Status::NOT_FOUND
    end
  end
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  begin
    yield "http://127.0.0.1:#{address.port}"
  ensure
    server.close
  end
end

describe "thumbnail sidecars" do
  it "writes the best thumbnail while skipping the media file" do
    with_thumbnail_server do |base_url|
      directory = File.join(Dir.tempdir, "cr-dlp-thumbs-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      begin
        options = CrDlp::ParsedOptions.new({
          "outtmpl" => JSON::Any.new({
            "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
          }),
          "writethumbnail" => JSON::Any.new(true),
          "skip_download"  => JSON::Any.new(true),
        })
        client = thumbnail_client(options, base_url)

        client.download(["thumbnail:fixture"]).should eq(0)
        File.read(File.join(directory, "thumbnail.jpg")).should eq("BEST")
        File.exists?(File.join(directory, "thumbnail.mp4")).should be_false
        File.exists?(File.join(directory, "thumbnail.png")).should be_false
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end

  it "falls back to an earlier thumbnail when the best URL fails" do
    with_thumbnail_server(HTTP::Status::NOT_FOUND) do |base_url|
      directory = File.join(Dir.tempdir, "cr-dlp-thumbs-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      begin
        options = CrDlp::ParsedOptions.new({
          "outtmpl" => JSON::Any.new({
            "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
          }),
          "writethumbnail" => JSON::Any.new(true),
          "skip_download"  => JSON::Any.new(true),
        })

        thumbnail_client(options, base_url).download(["thumbnail:fixture"]).should eq(0)
        File.read(File.join(directory, "thumbnail.png")).should eq("SMALL")
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end

  it "writes every thumbnail using IDs, thumbnail templates, and paths" do
    with_thumbnail_server do |base_url|
      directory = File.join(Dir.tempdir, "cr-dlp-thumbs-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      begin
        options = CrDlp::ParsedOptions.new({
          "outtmpl" => JSON::Any.new({
            "default"   => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
            "thumbnail" => JSON::Any.new("%(title)s.%(ext)s"),
          }),
          "paths" => JSON::Any.new({
            "thumbnail" => JSON::Any.new(File.join(directory, "images")),
          }),
          "writethumbnail" => JSON::Any.new("all"),
          "skip_download"  => JSON::Any.new(true),
        })

        thumbnail_client(options, base_url).download(["thumbnail:fixture"]).should eq(0)
        File.read(File.join(directory, "images", "thumbnail.small.png")).should eq("SMALL")
        File.read(File.join(directory, "images", "thumbnail.large_cover.jpg")).should eq("BEST")
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end

  it "converts downloaded thumbnails and publishes postprocessor hooks" do
    with_thumbnail_server do |base_url|
      directory = File.join(Dir.tempdir, "cr-dlp-thumbs-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      begin
        runner = ThumbnailProcessRunner.new
        options = CrDlp::ParsedOptions.new({
          "outtmpl" => JSON::Any.new({
            "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
          }),
          "writethumbnail"    => JSON::Any.new(true),
          "convertthumbnails" => JSON::Any.new("webp"),
          "skip_download"     => JSON::Any.new(true),
        })
        client = thumbnail_client(options, base_url, runner)
        events = [] of String
        client.add_postprocessor_hook do |event|
          events << "#{event["postprocessor"].as_s}:#{event["status"].as_s}"
        end

        client.download(["thumbnail:fixture"]).should eq(0)
        File.exists?(File.join(directory, "thumbnail.jpg")).should be_false
        File.read(File.join(directory, "thumbnail.webp")).should eq("CONVERTED")
        events.should contain("FFmpegThumbnailsConvertor:started")
        events.should contain("FFmpegThumbnailsConvertor:finished")
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end

  it "uses a single thumbnail URL when the thumbnails array is absent" do
    with_thumbnail_server do |base_url|
      directory = File.join(Dir.tempdir, "cr-dlp-thumbs-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      begin
        options = CrDlp::ParsedOptions.new({
          "outtmpl" => JSON::Any.new({
            "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
          }),
          "writethumbnail" => JSON::Any.new(true),
        })
        client = CrDlp::Client.new(options)
        info = CrDlp::Info.new
        info["id"] = "single"
        info["title"] = "single"
        info["url"] = "fixture://single"
        info["protocol"] = "fixture"
        info["ext"] = "mp4"
        info["fixture_data"] = "VIDEO"
        info["thumbnail"] = "#{base_url}/best.jpg"

        client.process_info(info)
        File.read(File.join(directory, "single.jpg")).should eq("BEST")
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end
end

describe CrDlp::FFmpegThumbnailsConvertorPostProcessor do
  it "applies source mappings, removes originals, and updates info" do
    directory = File.join(Dir.tempdir, "cr-dlp-thumbs-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "cover.jpg")
      File.write(source, "JPEG")
      info = CrDlp::Info.new({
        "thumbnails" => JSON::Any.new([
          JSON::Any.new({
            "ext"      => JSON::Any.new("jpg"),
            "filepath" => JSON::Any.new(source),
          }),
        ]),
      })
      runner = ThumbnailProcessRunner.new
      options = CrDlp::ParsedOptions.new({
        "convertthumbnails" => JSON::Any.new("jpg>webp/png"),
      })
      client = CrDlp::Client.new(options, process_runner: runner)

      CrDlp::FFmpegThumbnailsConvertorPostProcessor.new(client).run(info)
      destination = File.join(directory, "cover.webp")
      File.read(destination).should eq("CONVERTED")
      File.exists?(source).should be_false
      thumbnail = info.array?("thumbnails").not_nil!.first.as_h
      thumbnail["ext"].as_s.should eq("webp")
      thumbnail["filepath"].as_s.should eq(destination)
      runner.calls.first[1].last.should eq(destination)
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "converts a real generated image when ffmpeg is available" do
    ffmpeg = Process.find_executable("ffmpeg")
    pending!("ffmpeg is not available") unless ffmpeg

    directory = File.join(Dir.tempdir, "cr-dlp-thumbs-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "cover.png")
      Process.run(
        ffmpeg,
        ["-loglevel", "error", "-f", "lavfi", "-i", "color=c=red:s=8x8", "-frames:v", "1", source],
      ).success?.should be_true
      info = CrDlp::Info.new({
        "thumbnails" => JSON::Any.new([
          JSON::Any.new({
            "ext"      => JSON::Any.new("png"),
            "filepath" => JSON::Any.new(source),
          }),
        ]),
      })
      options = CrDlp::ParsedOptions.new({
        "convertthumbnails" => JSON::Any.new("webp"),
        "ffmpeg_location"   => JSON::Any.new(ffmpeg),
      })
      client = CrDlp::Client.new(options)

      CrDlp::FFmpegThumbnailsConvertorPostProcessor.new(client).run(info)
      destination = File.join(directory, "cover.webp")
      File.size(destination).should be > 0
      File.exists?(source).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
