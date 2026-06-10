require "./spec_helper"

private class FakeProcessRunner < CrDlp::ProcessRunner
  getter calls = [] of Tuple(String, Array(String))

  def initialize(@exit_code = 0, @error = "")
  end

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    @calls << {command, arguments.dup}
    if @exit_code == 0
      inputs = [] of String
      arguments.each_with_index do |argument, index|
        inputs << arguments[index + 1] if argument == "-i"
      end
      File.write(arguments.last, inputs.join { |path| File.read(path) })
    end
    CrDlp::ProcessResult.new(@exit_code, "", @error)
  end
end

private def merge_info : CrDlp::Info
  info = CrDlp::Info.new
  info["id"] = "merge"
  info["title"] = "merge"
  info["url"] = "fixture://default"
  info["formats"] = JSON::Any.new([
    JSON::Any.new({
      "format_id"    => JSON::Any.new("video"),
      "url"          => JSON::Any.new("fixture://video"),
      "protocol"     => JSON::Any.new("fixture"),
      "ext"          => JSON::Any.new("mp4"),
      "vcodec"       => JSON::Any.new("h264"),
      "acodec"       => JSON::Any.new("none"),
      "height"       => JSON::Any.new(1080_i64),
      "fixture_data" => JSON::Any.new("VIDEO"),
    }),
    JSON::Any.new({
      "format_id"    => JSON::Any.new("audio"),
      "url"          => JSON::Any.new("fixture://audio"),
      "protocol"     => JSON::Any.new("fixture"),
      "ext"          => JSON::Any.new("m4a"),
      "vcodec"       => JSON::Any.new("none"),
      "acodec"       => JSON::Any.new("aac"),
      "fixture_data" => JSON::Any.new("AUDIO"),
    }),
  ])
  CrDlp::FormatSelector.select!(info, "bestvideo+bestaudio")
end

describe CrDlp::FFmpegMergerPostProcessor do
  it "downloads components, invokes ffmpeg, and removes intermediates" do
    directory = File.join(Dir.tempdir, "cr-dlp-merge-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      runner = FakeProcessRunner.new
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
        }),
      })
      client = CrDlp::Client.new(options, process_runner: runner)
      info = client.process_info(merge_info)

      output = File.join(directory, "merge.mp4")
      File.read(output).should eq("VIDEOAUDIO")
      info.string?("filepath").should eq(output)
      Dir.children(directory).select(&.includes?(".f")).should be_empty
      command, arguments = runner.calls.first
      command.should eq("ffmpeg")
      arguments.count("-i").should eq(2)
      arguments.last.should end_with(".temp.mp4")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "preserves intermediates and reports stderr when ffmpeg fails" do
    directory = File.join(Dir.tempdir, "cr-dlp-merge-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      runner = FakeProcessRunner.new(1, "invalid input")
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
        }),
      })
      client = CrDlp::Client.new(options, process_runner: runner)

      expect_raises(CrDlp::PostProcessingError, "ffmpeg merge failed: invalid input") do
        client.process_info(merge_info)
      end
      Dir.children(directory).count(&.includes?(".f")).should eq(2)
      File.exists?(File.join(directory, "merge.mp4")).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "honors ffmpeg location and keep-video" do
    directory = File.join(Dir.tempdir, "cr-dlp-merge-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      runner = FakeProcessRunner.new
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
        }),
        "ffmpeg_location" => JSON::Any.new("custom-ffmpeg"),
        "keepvideo"       => JSON::Any.new(true),
      })
      client = CrDlp::Client.new(options, process_runner: runner)
      client.process_info(merge_info)

      runner.calls.first[0].should eq("custom-ffmpeg")
      Dir.children(directory).count(&.includes?(".f")).should eq(2)
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "merges real audio and video streams when ffmpeg is available" do
    ffmpeg = Process.find_executable("ffmpeg")
    pending!("ffmpeg is not available") unless ffmpeg

    directory = File.join(Dir.tempdir, "cr-dlp-merge-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      video = File.join(directory, "video.mp4")
      audio = File.join(directory, "audio.m4a")
      output = File.join(directory, "merged.mp4")
      Process.run(
        ffmpeg,
        [
          "-loglevel", "error", "-f", "lavfi", "-i",
          "color=c=black:s=16x16:d=0.2", "-an", "-c:v", "mpeg4", video,
        ],
      ).success?.should be_true
      Process.run(
        ffmpeg,
        [
          "-loglevel", "error", "-f", "lavfi", "-i",
          "sine=frequency=440:duration=0.2", "-vn", "-c:a", "aac", audio,
        ],
      ).success?.should be_true

      info = CrDlp::Info.new
      info["_filename"] = output
      info.sidecar["merger_inputs"] = CrDlp::MergerInputs.new([video, audio])
      client = CrDlp::Client.new(process_runner: CrDlp::SystemProcessRunner.new)
      CrDlp::FFmpegMergerPostProcessor.new(client).run(info)

      File.size(output).should be > 0
      File.exists?(video).should be_false
      File.exists?(audio).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
