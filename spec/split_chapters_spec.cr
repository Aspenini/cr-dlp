require "./spec_helper"

private class SplitChapterRunner < CrDlp::ProcessRunner
  getter calls = [] of Tuple(String, Array(String))

  def initialize(@succeeds = true)
  end

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    @calls << {command, arguments.dup}
    return CrDlp::ProcessResult.new(1, "", "split failed") unless @succeeds
    File.write(arguments.last, "CHAPTER #{@calls.size}")
    CrDlp::ProcessResult.new(0, "", "")
  end
end

private def split_info(path : String) : CrDlp::Info
  CrDlp::Info.new({
    "id"       => JSON::Any.new("split"),
    "title"    => JSON::Any.new("Whole Video"),
    "ext"      => JSON::Any.new("mp4"),
    "filepath" => JSON::Any.new(path),
    "duration" => JSON::Any.new(4.0),
    "chapters" => JSON::Any.new([
      JSON::Any.new({
        "start_time" => JSON::Any.new(0.0),
        "end_time"   => JSON::Any.new(1.5),
        "title"      => JSON::Any.new("Opening"),
      }),
      JSON::Any.new({
        "start_time" => JSON::Any.new(1.5),
        "end_time"   => JSON::Any.new(4.0),
        "title"      => JSON::Any.new("Ending"),
      }),
    ]),
  })
end

describe CrDlp::FFmpegSplitChaptersPostProcessor do
  it "splits chapters using chapter templates and records filepaths" do
    directory = File.join(Dir.tempdir, "cr-dlp-split-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "whole.mp4")
      File.write(source, "MEDIA")
      runner = SplitChapterRunner.new
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "chapter" => JSON::Any.new("%(section_number)02d-%(section_title)s.%(ext)s"),
        }),
        "paths" => JSON::Any.new({
          "chapter" => JSON::Any.new(directory),
        }),
      })
      client = CrDlp::Client.new(options, process_runner: runner, auto_init: false)
      info = split_info(source)

      CrDlp::FFmpegSplitChaptersPostProcessor.new(client).run(info)

      first = File.join(directory, "01-Opening.mp4")
      second = File.join(directory, "02-Ending.mp4")
      File.read(first).should eq("CHAPTER 1")
      File.read(second).should eq("CHAPTER 2")
      chapters = info.array?("chapters").not_nil!
      chapters[0].as_h["filepath"].as_s.should eq(first)
      chapters[1].as_h["filepath"].as_s.should eq(second)
      runner.calls[0][1].each_cons(2).to_a.should contain(["-ss", "0.0"])
      runner.calls[0][1].each_cons(2).to_a.should contain(["-t", "1.5"])
      runner.calls[1][1].each_cons(2).to_a.should contain(["-ss", "1.5"])
      runner.calls[1][1].each_cons(2).to_a.should contain(["-t", "2.5"])
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "creates a keyframed intermediate when requested" do
    directory = File.join(Dir.tempdir, "cr-dlp-split-keyframes-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "whole.mp4")
      File.write(source, "MEDIA")
      runner = SplitChapterRunner.new
      options = CrDlp::ParsedOptions.new({
        "force_keyframes_at_cuts" => JSON::Any.new(true),
        "paths"                   => JSON::Any.new({
          "chapter" => JSON::Any.new(directory),
        }),
      })
      client = CrDlp::Client.new(options, process_runner: runner, auto_init: false)

      CrDlp::FFmpegSplitChaptersPostProcessor.new(client).run(split_info(source))

      runner.calls.size.should eq(3)
      runner.calls.first[1].should contain("-force_key_frames")
      runner.calls.first[1].should contain("1.500000")
      File.exists?(File.join(directory, "whole.keyframes.temp.mp4")).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "removes partial chapter outputs after failure" do
    directory = File.join(Dir.tempdir, "cr-dlp-split-failure-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "whole.mp4")
      File.write(source, "MEDIA")
      client = CrDlp::Client.new(
        CrDlp::ParsedOptions.new({
          "paths" => JSON::Any.new({
            "chapter" => JSON::Any.new(directory),
          }),
        }),
        process_runner: SplitChapterRunner.new(succeeds: false),
        auto_init: false,
      )

      expect_raises(CrDlp::PostProcessingError, "split failed") do
        CrDlp::FFmpegSplitChaptersPostProcessor.new(client).run(split_info(source))
      end
      Dir.glob(File.join(directory, "*Whole Video*")).should be_empty
      File.read(source).should eq("MEDIA")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "moves split chapter outputs from temp to home" do
    directory = File.join(Dir.tempdir, "cr-dlp-split-move-#{Random::Secure.hex(6)}")
    temp = File.join(directory, "temp")
    home = File.join(directory, "home")
    Dir.mkdir_p(temp)
    begin
      media = File.join(temp, "whole.mp4")
      chapter_path = File.join(temp, "01-Opening.mp4")
      File.write(media, "MEDIA")
      File.write(chapter_path, "CHAPTER")
      info = split_info(media)
      info.array?("chapters").not_nil!.first.as_h["filepath"] = JSON::Any.new(chapter_path)
      info.sidecar["move_plan"] = CrDlp::MovePlan.new(
        temp,
        home,
        File.join(home, "whole.mp4"),
      )

      CrDlp::MoveFilesAfterDownloadPostProcessor.new(
        CrDlp::Client.new(auto_init: false),
      ).run(info)

      File.read(File.join(home, "01-Opening.mp4")).should eq("CHAPTER")
      info.array?("chapters").not_nil!.first.as_h["filepath"].as_s
        .should eq(File.join(home, "01-Opening.mp4"))
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "creates playable chapter files with real ffmpeg" do
    ffmpeg = Process.find_executable("ffmpeg")
    ffprobe = Process.find_executable("ffprobe")
    pending!("ffmpeg and ffprobe are required") unless ffmpeg && ffprobe

    directory = File.join(Dir.tempdir, "cr-dlp-real-split-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      source = File.join(directory, "whole.mp4")
      generation = Process.run(
        ffmpeg,
        [
          "-y", "-loglevel", "error",
          "-f", "lavfi", "-i", "testsrc=size=64x64:rate=10:duration=4",
          "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
          "-c:v", "mpeg4", "-g", "10", "-c:a", "aac", "-shortest", source,
        ],
      )
      generation.success?.should be_true

      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "chapter" => JSON::Any.new("%(section_number)02d.%(ext)s"),
        }),
        "paths" => JSON::Any.new({
          "chapter" => JSON::Any.new(directory),
        }),
      })
      client = CrDlp::Client.new(options, auto_init: false)
      info = split_info(source)
      CrDlp::FFmpegSplitChaptersPostProcessor.new(client).run(info)

      expected = {File.join(directory, "01.mp4") => 1.5, File.join(directory, "02.mp4") => 2.5}
      expected.each do |path, target_duration|
        File.size(path).should be > 0
        output = IO::Memory.new
        status = Process.run(
          ffprobe,
          [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=nw=1:nk=1",
            path,
          ],
          output: output,
        )
        status.success?.should be_true
        output.to_s.strip.to_f.should be_close(target_duration, 0.35)
      end
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
