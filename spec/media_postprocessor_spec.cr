require "./spec_helper"

private class MediaTransformRunner < CrDlp::ProcessRunner
  getter calls = [] of Tuple(String, Array(String))
  getter shell_calls = [] of String

  def initialize(@succeeds = true, @available = true)
  end

  def executable_available?(command : String) : Bool
    @available
  end

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    @calls << {command, arguments.dup}
    if @succeeds
      input_index = arguments.index("-i")
      source = input_index.try { |index| arguments[index + 1]? }
      contents = source && File.exists?(source) ? File.read(source) : ""
      File.write(arguments.last, "#{contents}:processed")
      CrDlp::ProcessResult.new(0, "", "")
    else
      CrDlp::ProcessResult.new(1, "", "conversion failed")
    end
  end

  def run_shell(command : String) : CrDlp::ProcessResult
    @shell_calls << command
    CrDlp::ProcessResult.new(@succeeds ? 0 : 7, "", "")
  end
end

private def media_info(path : String, extension = "mp4", codec = "aac") : CrDlp::Info
  CrDlp::Info.new({
    "id"        => JSON::Any.new("media"),
    "title"     => JSON::Any.new("Media Title"),
    "url"       => JSON::Any.new("fixture://media"),
    "protocol"  => JSON::Any.new("fixture"),
    "ext"       => JSON::Any.new(extension),
    "acodec"    => JSON::Any.new(codec),
    "filepath"  => JSON::Any.new(path),
    "_filename" => JSON::Any.new(path),
  })
end

describe CrDlp::FFmpegExtractAudioPostProcessor do
  it "extracts audio losslessly when possible and removes the source" do
    directory = File.join(Dir.tempdir, "cr-dlp-audio-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "media.mp4")
      File.write(source, "SOURCE")
      runner = MediaTransformRunner.new
      options = CrDlp::ParsedOptions.new({
        "audioformat" => JSON::Any.new("m4a"),
      })
      info = media_info(source)
      result = CrDlp::FFmpegExtractAudioPostProcessor.new(
        CrDlp::Client.new(options, process_runner: runner, auto_init: false)
      ).run(info)

      destination = File.join(directory, "media.m4a")
      result.string?("filepath").should eq(destination)
      result.string?("ext").should eq("m4a")
      File.read(destination).should eq("SOURCE:processed")
      File.exists?(source).should be_false
      arguments = runner.calls.first[1]
      arguments.should contain("-vn")
      arguments.should contain("copy")
      arguments.should contain("aac_adtstoasc")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "applies bitrate quality and preserves source with keep-video" do
    directory = File.join(Dir.tempdir, "cr-dlp-audio-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "media.webm")
      File.write(source, "SOURCE")
      runner = MediaTransformRunner.new
      options = CrDlp::ParsedOptions.new({
        "audioformat"  => JSON::Any.new("mp3"),
        "audioquality" => JSON::Any.new("128K"),
        "keepvideo"    => JSON::Any.new(true),
      })
      info = media_info(source, "webm", "opus")
      CrDlp::FFmpegExtractAudioPostProcessor.new(
        CrDlp::Client.new(options, process_runner: runner, auto_init: false)
      ).run(info)

      File.exists?(source).should be_true
      arguments = runner.calls.first[1]
      arguments.should contain("libmp3lame")
      arguments.each_cons(2).to_a.should contain(["-b:a", "128k"])
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "leaves the original untouched when ffmpeg fails" do
    directory = File.join(Dir.tempdir, "cr-dlp-audio-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "media.mp4")
      File.write(source, "SOURCE")
      client = CrDlp::Client.new(
        CrDlp::ParsedOptions.new({"audioformat" => JSON::Any.new("mp3")}),
        process_runner: MediaTransformRunner.new(succeeds: false),
        auto_init: false,
      )
      expect_raises(CrDlp::PostProcessingError, "conversion failed") do
        CrDlp::FFmpegExtractAudioPostProcessor.new(client).run(media_info(source))
      end
      File.read(source).should eq("SOURCE")
      File.exists?(File.join(directory, "media.mp3")).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "extracts a playable audio file with real ffmpeg" do
    ffmpeg = Process.find_executable("ffmpeg")
    ffprobe = Process.find_executable("ffprobe")
    pending!("ffmpeg and ffprobe are required") unless ffmpeg && ffprobe

    directory = File.join(Dir.tempdir, "cr-dlp-real-audio-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "source.mp4")
      generation = Process.run(
        ffmpeg,
        [
          "-y", "-loglevel", "error",
          "-f", "lavfi", "-i", "color=c=black:s=64x64:d=0.2",
          "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2",
          "-shortest", "-c:v", "mpeg4", "-c:a", "aac", source,
        ],
      )
      generation.success?.should be_true

      options = CrDlp::ParsedOptions.new({
        "audioformat" => JSON::Any.new("m4a"),
      })
      client = CrDlp::Client.new(options, auto_init: false)
      result = CrDlp::FFmpegExtractAudioPostProcessor.new(client)
        .run(media_info(source))
      destination = result.string?("filepath").not_nil!
      File.size(destination).should be > 0

      probe_output = IO::Memory.new
      probe = Process.run(
        ffprobe,
        ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name", "-of", "default=nw=1", destination],
        output: probe_output,
      )
      probe.success?.should be_true
      probe_output.to_s.should contain("codec_name=aac")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

describe "video transform postprocessors" do
  it "resolves remux mappings and copies streams" do
    directory = File.join(Dir.tempdir, "cr-dlp-remux-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "media.webm")
      File.write(source, "SOURCE")
      runner = MediaTransformRunner.new
      client = CrDlp::Client.new(
        CrDlp::ParsedOptions.new({
          "remuxvideo" => JSON::Any.new("mov>mp4/mkv"),
          "keepvideo"  => JSON::Any.new(true),
        }),
        process_runner: runner,
        auto_init: false,
      )
      result = CrDlp::FFmpegVideoRemuxerPostProcessor.new(client)
        .run(media_info(source, "webm", "opus"))

      result.string?("ext").should eq("mkv")
      File.exists?(source).should be_true
      runner.calls.first[1].each_cons(2).to_a.should contain(["-c", "copy"])
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "uses the AVI conversion codec and deletes the source" do
    directory = File.join(Dir.tempdir, "cr-dlp-recode-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "media.mp4")
      File.write(source, "SOURCE")
      runner = MediaTransformRunner.new
      client = CrDlp::Client.new(
        CrDlp::ParsedOptions.new({"recodevideo" => JSON::Any.new("avi")}),
        process_runner: runner,
        auto_init: false,
      )
      result = CrDlp::FFmpegVideoConvertorPostProcessor.new(client).run(media_info(source))

      result.string?("ext").should eq("avi")
      File.exists?(source).should be_false
      runner.calls.first[1].should contain("libxvid")
      runner.calls.first[1].should contain("XVID")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

describe CrDlp::FFmpegMetadataPostProcessor do
  it "embeds common, custom, stream, and chapter metadata" do
    directory = File.join(Dir.tempdir, "cr-dlp-metadata-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "media.mp4")
      File.write(source, "SOURCE")
      runner = MediaTransformRunner.new
      client = CrDlp::Client.new(
        CrDlp::ParsedOptions.new({
          "addmetadata" => JSON::Any.new(true),
        }),
        process_runner: runner,
        auto_init: false,
      )
      info = media_info(source)
      info["upload_date"] = "20260606"
      info["artist"] = JSON::Any.new([
        JSON::Any.new("First Artist"),
        JSON::Any.new("Second Artist"),
      ])
      info["webpage_url"] = "https://example.test/watch"
      info["meta_genre"] = "Crystal"
      info["meta0_handler_name"] = "Main stream"
      info["language"] = "en"
      info["chapters"] = JSON::Any.new([
        JSON::Any.new({
          "start_time" => JSON::Any.new(0_i64),
          "end_time"   => JSON::Any.new(1.25),
          "title"      => JSON::Any.new("Intro; Part #1"),
        }),
      ])

      CrDlp::FFmpegMetadataPostProcessor.new(client).run(info)

      File.read(source).should eq("SOURCE:processed")
      arguments = runner.calls.first[1]
      arguments.each_cons(2).to_a.should contain(["-metadata", "title=Media Title"])
      arguments.each_cons(2).to_a.should contain(["-metadata", "artist=First Artist, Second Artist"])
      arguments.each_cons(2).to_a.should contain(["-metadata", "genre=Crystal"])
      arguments.each_cons(2).to_a.should contain(["-metadata:s:0", "handler_name=Main stream"])
      arguments.each_cons(2).to_a.should contain(["-metadata:s:0", "language=eng"])
      arguments.each_cons(2).to_a.should contain(["-map_metadata", "1"])
      Dir.glob(File.join(directory, "*.meta")).should be_empty
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "attaches generated info JSON to Matroska files" do
    directory = File.join(Dir.tempdir, "cr-dlp-infojson-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "media.mkv")
      File.write(source, "SOURCE")
      runner = MediaTransformRunner.new
      client = CrDlp::Client.new(
        CrDlp::ParsedOptions.new({
          "embed_infojson" => JSON::Any.new(true),
        }),
        process_runner: runner,
        auto_init: false,
      )
      info = media_info(source, "mkv")

      CrDlp::FFmpegMetadataPostProcessor.new(client).run(info)

      arguments = runner.calls.first[1]
      attachment = arguments[arguments.index("-attach").not_nil! + 1]
      arguments.each_cons(2).to_a.should contain(["-metadata:s:t", "mimetype=application/json"])
      File.exists?(attachment).should be_false
      File.read(source).should eq("SOURCE:processed")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "rolls back when metadata embedding fails" do
    directory = File.join(Dir.tempdir, "cr-dlp-metadata-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "media.mp4")
      File.write(source, "SOURCE")
      client = CrDlp::Client.new(
        CrDlp::ParsedOptions.new({"addmetadata" => JSON::Any.new(true)}),
        process_runner: MediaTransformRunner.new(succeeds: false),
        auto_init: false,
      )
      expect_raises(CrDlp::PostProcessingError, "conversion failed") do
        CrDlp::FFmpegMetadataPostProcessor.new(client).run(media_info(source))
      end
      File.read(source).should eq("SOURCE")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "writes readable tags with real ffmpeg" do
    ffmpeg = Process.find_executable("ffmpeg")
    ffprobe = Process.find_executable("ffprobe")
    pending!("ffmpeg and ffprobe are required") unless ffmpeg && ffprobe

    directory = File.join(Dir.tempdir, "cr-dlp-real-metadata-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "source.m4a")
      generation = Process.run(
        ffmpeg,
        [
          "-y", "-loglevel", "error",
          "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2",
          "-c:a", "aac", source,
        ],
      )
      generation.success?.should be_true

      client = CrDlp::Client.new(
        CrDlp::ParsedOptions.new({"addmetadata" => JSON::Any.new(true)}),
        auto_init: false,
      )
      info = media_info(source, "m4a")
      info["artist"] = "Crystal Artist"
      CrDlp::FFmpegMetadataPostProcessor.new(client).run(info)

      probe_output = IO::Memory.new
      probe = Process.run(
        ffprobe,
        [
          "-v", "error",
          "-show_entries", "format_tags=title,artist",
          "-of", "default=nw=1", source,
        ],
        output: probe_output,
      )
      probe.success?.should be_true
      probe_output.to_s.should contain("TAG:title=Media Title")
      probe_output.to_s.should contain("TAG:artist=Crystal Artist")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

describe "postprocessor pipeline scheduling" do
  it "chains extraction, staged exec, and temp-to-home movement" do
    directory = File.join(Dir.tempdir, "cr-dlp-pipeline-#{Random::Secure.hex(6)}")
    temp = File.join(directory, "temp")
    home = File.join(directory, "home")
    Dir.mkdir_p(temp)
    Dir.mkdir_p(home)
    begin
      runner = MediaTransformRunner.new
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new("%(id)s.%(ext)s"),
        }),
        "paths" => JSON::Any.new({
          "temp" => JSON::Any.new(temp),
          "home" => JSON::Any.new(home),
        }),
        "extractaudio" => JSON::Any.new(true),
        "audioformat"  => JSON::Any.new("mp3"),
        "audioquality" => JSON::Any.new("5"),
        "addmetadata"  => JSON::Any.new(true),
        "fixup"        => JSON::Any.new("never"),
        "exec_cmd"     => JSON::Any.new({
          "before_dl"    => JSON::Any.new([JSON::Any.new("before")]),
          "post_process" => JSON::Any.new([JSON::Any.new("post")]),
          "after_move"   => JSON::Any.new([JSON::Any.new("after")]),
          "after_video"  => JSON::Any.new([JSON::Any.new("video %(filepath)q")]),
        }),
      })
      client = CrDlp::Client.new(options, process_runner: runner)
      info = CrDlp::Info.new({
        "id"           => JSON::Any.new("fixture"),
        "title"        => JSON::Any.new("fixture"),
        "url"          => JSON::Any.new("fixture://fixture"),
        "protocol"     => JSON::Any.new("fixture"),
        "ext"          => JSON::Any.new("mp4"),
        "acodec"       => JSON::Any.new("aac"),
        "fixture_data" => JSON::Any.new("MEDIA"),
      })

      result = client.process_info(info)
      final_path = File.join(home, "fixture.mp3")
      result.string?("filepath").should eq(final_path)
      File.read(final_path).should eq("MEDIA:processed:processed")
      runner.calls.size.should eq(2)
      Dir.glob(File.join(temp, "**", "*")).select { |path| File.file?(path) }.should be_empty
      runner.shell_calls.size.should eq(4)
      runner.shell_calls[0].should contain(File.join(temp, "fixture.mp4"))
      runner.shell_calls[1].should contain(File.join(temp, "fixture.mp3"))
      runner.shell_calls[2].should contain(final_path)
      runner.shell_calls[3].should contain(final_path)
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "moves downloaded subtitle and thumbnail sidecars with the media" do
    directory = File.join(Dir.tempdir, "cr-dlp-move-#{Random::Secure.hex(6)}")
    temp = File.join(directory, "temp")
    home = File.join(directory, "home")
    Dir.mkdir_p(temp)
    begin
      media = File.join(temp, "media.mp4")
      subtitle = File.join(temp, "media.en.vtt")
      thumbnail = File.join(temp, "media.jpg")
      infojson = File.join(temp, "media.info.json")
      {media => "MEDIA", subtitle => "SUB", thumbnail => "IMAGE", infojson => "{}"}.each do |path, data|
        File.write(path, data)
      end
      info = media_info(media)
      info["infojson_filename"] = infojson
      info["requested_subtitles"] = JSON::Any.new({
        "en" => JSON::Any.new({
          "filepath" => JSON::Any.new(subtitle),
          "ext"      => JSON::Any.new("vtt"),
        }),
      })
      info["thumbnails"] = JSON::Any.new([
        JSON::Any.new({"filepath" => JSON::Any.new(thumbnail)}),
      ])
      info.sidecar["move_plan"] = CrDlp::MovePlan.new(
        temp,
        home,
        File.join(home, "media.mp4"),
      )
      client = CrDlp::Client.new(auto_init: false)
      CrDlp::MoveFilesAfterDownloadPostProcessor.new(client).run(info)

      File.read(File.join(home, "media.mp4")).should eq("MEDIA")
      File.read(File.join(home, "media.en.vtt")).should eq("SUB")
      File.read(File.join(home, "media.jpg")).should eq("IMAGE")
      File.read(File.join(home, "media.info.json")).should eq("{}")
      info.string?("infojson_filename").should eq(File.join(home, "media.info.json"))
      info.hash?("requested_subtitles").not_nil!["en"].as_h["filepath"].as_s
        .should eq(File.join(home, "media.en.vtt"))
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "raises when an exec command fails" do
    client = CrDlp::Client.new(
      process_runner: MediaTransformRunner.new(succeeds: false),
      auto_init: false,
    )
    expect_raises(CrDlp::PostProcessingError, "error code 7") do
      CrDlp::ExecPostProcessor.new(client, ["false"]).run(
        media_info("file name.mp4")
      )
    end
  end

  it "writes, embeds, and moves info JSON in the download pipeline" do
    directory = File.join(Dir.tempdir, "cr-dlp-infojson-pipeline-#{Random::Secure.hex(6)}")
    temp = File.join(directory, "temp")
    home = File.join(directory, "home")
    Dir.mkdir_p(temp)
    begin
      runner = MediaTransformRunner.new
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new("%(id)s.%(ext)s"),
        }),
        "paths" => JSON::Any.new({
          "temp" => JSON::Any.new(temp),
          "home" => JSON::Any.new(home),
        }),
        "writeinfojson" => JSON::Any.new(true),
        "addmetadata"   => JSON::Any.new(true),
        "fixup"         => JSON::Any.new("never"),
      })
      client = CrDlp::Client.new(options, process_runner: runner)
      info = CrDlp::Info.new({
        "id"           => JSON::Any.new("fixture"),
        "title"        => JSON::Any.new("fixture"),
        "url"          => JSON::Any.new("fixture://fixture"),
        "protocol"     => JSON::Any.new("fixture"),
        "ext"          => JSON::Any.new("mkv"),
        "fixture_data" => JSON::Any.new("MEDIA"),
      })

      result = client.process_info(info)
      final_media = File.join(home, "fixture.mkv")
      final_infojson = File.join(home, "fixture.info.json")
      File.read(final_media).should eq("MEDIA:processed")
      File.exists?(final_infojson).should be_true
      result.string?("infojson_filename").should eq(final_infojson)
      arguments = runner.calls.first[1]
      attachment = arguments[arguments.index("-attach").not_nil! + 1]
      attachment.should eq(File.join(temp, "fixture.info.json"))
      Dir.glob(File.join(temp, "**", "*")).select { |path| File.file?(path) }.should be_empty
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
