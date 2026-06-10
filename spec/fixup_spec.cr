require "./spec_helper"

private class FixupProcessRunner < CrDlp::ProcessRunner
  getter calls = [] of Tuple(String, Array(String))

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    @calls << {command, arguments.dup}
    File.write(arguments.last, "FIXED")
    CrDlp::ProcessResult.new(0, "", "")
  end
end

private class UnavailableFixupRunner < FixupProcessRunner
  def executable_available?(command : String) : Bool
    false
  end
end

private class FailingFixupRunner < CrDlp::ProcessRunner
  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    CrDlp::ProcessResult.new(1, "", "fixup failed")
  end
end

private def fixup_info(path : String, extension = "mp4") : CrDlp::Info
  CrDlp::Info.new({
    "id"           => JSON::Any.new("fixup"),
    "title"        => JSON::Any.new("fixup"),
    "url"          => JSON::Any.new("fixture://fixup"),
    "protocol"     => JSON::Any.new("fixture"),
    "ext"          => JSON::Any.new(extension),
    "fixture_data" => JSON::Any.new("ORIGINAL"),
    "filepath"     => JSON::Any.new(path),
  })
end

describe "automatic ffmpeg fixups" do
  it "detects stretched video, runs before ordinary postprocessors, and publishes hooks" do
    directory = File.join(Dir.tempdir, "cr-dlp-fixup-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      runner = FixupProcessRunner.new
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
        }),
      })
      client = CrDlp::Client.new(options, process_runner: runner)
      events = [] of String
      client.add_postprocessor_hook do |event|
        events << "#{event["postprocessor"].as_s}:#{event["status"].as_s}"
      end
      info = fixup_info(File.join(directory, "fixup.mp4"))
      info["stretched_ratio"] = 1.5

      client.process_info(info)

      File.read(File.join(directory, "fixup.mp4")).should eq("FIXED")
      runner.calls.size.should eq(1)
      runner.calls.first[1].should contain("-aspect")
      runner.calls.first[1].should contain("1.5")
      events.index("FFmpegFixupStretched:finished").not_nil!
        .should be < events.index("Metadata:started").not_nil!
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "honors warn and never policies without invoking ffmpeg" do
    %w[warn never].each do |policy|
      directory = File.join(Dir.tempdir, "cr-dlp-fixup-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      begin
        runner = FixupProcessRunner.new
        options = CrDlp::ParsedOptions.new({
          "outtmpl" => JSON::Any.new({
            "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
          }),
          "fixup" => JSON::Any.new(policy),
        })
        info = fixup_info(File.join(directory, "fixup.mp4"))
        info["stretched_ratio"] = 1.5

        CrDlp::Client.new(options, process_runner: runner).process_info(info)
        runner.calls.should be_empty
        File.read(File.join(directory, "fixup.mp4")).should eq("ORIGINAL")
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end

  it "schedules M4A-DASH and native-HLS repairs from format metadata" do
    [
      {
        "extension" => "m4a",
        "protocol"  => "fixture",
        "extra"     => {"container" => JSON::Any.new("m4a_dash")},
        "expected"  => "FFmpegFixupM4a",
      },
      {
        "extension" => "mp4",
        "protocol"  => "m3u8_native",
        "extra"     => {"acodec" => JSON::Any.new("aac")},
        "expected"  => "FFmpegFixupM3u8",
      },
    ].each do |test_case|
      directory = File.join(Dir.tempdir, "cr-dlp-fixup-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      begin
        runner = FixupProcessRunner.new
        options = CrDlp::ParsedOptions.new({
          "outtmpl" => JSON::Any.new({
            "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
          }),
        })
        registry = CrDlp::DownloaderRegistry.new
        registry.register(["m3u8_native"]) { |client| CrDlp::FixtureDownloader.new(client) }
        client = CrDlp::Client.new(
          options,
          downloader_registry: registry,
          process_runner: runner,
        )
        events = [] of String
        client.add_postprocessor_hook do |event|
          events << event["postprocessor"].as_s if event["status"].as_s == "started"
        end
        extension = test_case["extension"].as(String)
        info = fixup_info(File.join(directory, "fixup.#{extension}"), extension)
        info["protocol"] = test_case["protocol"].as(String)
        info.merge!(test_case["extra"].as(Hash(String, JSON::Any)))

        client.process_info(info)

        events.should contain(test_case["expected"].as(String))
        runner.calls.size.should eq(1)
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end

  it "rejects unknown fixup policies" do
    directory = File.join(Dir.tempdir, "cr-dlp-fixup-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
        }),
        "fixup" => JSON::Any.new("sometimes"),
      })
      info = fixup_info(File.join(directory, "fixup.mp4"))

      expect_raises(CrDlp::UsageError, /Invalid fixup policy/) do
        CrDlp::Client.new(options).process_info(info)
      end
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "warns instead of failing when ffmpeg is unavailable" do
    directory = File.join(Dir.tempdir, "cr-dlp-fixup-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      runner = UnavailableFixupRunner.new
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
        }),
      })
      info = fixup_info(File.join(directory, "fixup.mp4"))
      info["stretched_ratio"] = 1.5

      CrDlp::Client.new(options, process_runner: runner).process_info(info)
      runner.calls.should be_empty
      File.read(File.join(directory, "fixup.mp4")).should eq("ORIGINAL")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

describe CrDlp::FFmpegFixupPostProcessor do
  it "constructs M4A, HLS, timestamp, duration, and duplicate-MOOV repairs" do
    directory = File.join(Dir.tempdir, "cr-dlp-fixup-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      cases = [
        {
          CrDlp::FFmpegFixupM4aPostProcessor,
          "m4a",
          {"container" => JSON::Any.new("m4a_dash")},
          ["-f", "mp4"],
        },
        {
          CrDlp::FFmpegFixupM3u8PostProcessor,
          "mp4",
          {
            "protocol" => JSON::Any.new("m3u8_native"),
            "acodec"   => JSON::Any.new("aac"),
          },
          ["-bsf:a", "aac_adtstoasc"],
        },
        {
          CrDlp::FFmpegFixupTimestampPostProcessor,
          "mp4",
          Hash(String, JSON::Any).new,
          ["-bsf", "setts=ts=TS-STARTPTS"],
        },
        {
          CrDlp::FFmpegFixupDurationPostProcessor,
          "mp4",
          Hash(String, JSON::Any).new,
          ["-c", "copy"],
        },
        {
          CrDlp::FFmpegFixupDuplicateMoovPostProcessor,
          "mp4",
          Hash(String, JSON::Any).new,
          ["-c", "copy"],
        },
      ]

      cases.each_with_index do |(processor_class, extension, extra, expected), index|
        media = File.join(directory, "case-#{index}.#{extension}")
        File.write(media, "ORIGINAL")
        info = fixup_info(media, extension)
        info.merge!(extra)
        runner = FixupProcessRunner.new
        client = CrDlp::Client.new(process_runner: runner)

        processor_class.new(client).run(info)

        File.read(media).should eq("FIXED")
        arguments = runner.calls.first[1]
        expected.each { |argument| arguments.should contain(argument) }
      end
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "preserves the original media when a repair fails" do
    directory = File.join(Dir.tempdir, "cr-dlp-fixup-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      media = File.join(directory, "video.mp4")
      File.write(media, "ORIGINAL")
      info = fixup_info(media)
      info["stretched_ratio"] = 1.5
      client = CrDlp::Client.new(process_runner: FailingFixupRunner.new)

      expect_raises(CrDlp::PostProcessingError, /fixup failed/) do
        CrDlp::FFmpegFixupStretchedPostProcessor.new(client).run(info)
      end
      File.read(media).should eq("ORIGINAL")
      File.exists?(File.join(directory, "video.temp.mp4")).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "remuxes a real MPEG-TS payload into an MP4 container" do
    ffmpeg = Process.find_executable("ffmpeg")
    ffprobe = Process.find_executable("ffprobe")
    pending!("ffmpeg and ffprobe are required") unless ffmpeg && ffprobe

    directory = File.join(Dir.tempdir, "cr-dlp-fixup-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      media = File.join(directory, "broken.mp4")
      Process.run(
        ffmpeg,
        [
          "-loglevel", "error",
          "-f", "lavfi", "-i", "testsrc2=size=16x16:rate=2:duration=1",
          "-f", "lavfi", "-i", "sine=frequency=1000:duration=1",
          "-c:v", "mpeg2video", "-c:a", "aac", "-f", "mpegts", media,
        ],
      ).success?.should be_true
      info = fixup_info(media)
      info["protocol"] = "m3u8_native"
      info["acodec"] = "aac"
      options = CrDlp::ParsedOptions.new({
        "ffmpeg_location" => JSON::Any.new(ffmpeg),
      })

      CrDlp::FFmpegFixupM3u8PostProcessor.new(
        CrDlp::Client.new(options),
      ).run(info)
      output = IO::Memory.new
      Process.run(
        ffprobe,
        ["-v", "error", "-show_entries", "format=format_name", "-of", "json", media],
        output: output,
      ).success?.should be_true
      JSON.parse(output.to_s)["format"]["format_name"].as_s.should contain("mp4")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
