require "./spec_helper"

private class ConcatRunner < CrDlp::ProcessRunner
  getter calls = [] of Tuple(String, Array(String))

  def initialize(@succeeds = true, @probe_signatures = [] of Array(String))
  end

  def executable_available?(command : String) : Bool
    command.includes?("ffprobe") ? !@probe_signatures.empty? : true
  end

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    @calls << {command, arguments.dup}
    unless @succeeds
      return CrDlp::ProcessResult.new(1, "", "concat failed")
    end
    if command.includes?("ffprobe")
      signature = @probe_signatures.shift
      streams = signature.map do |codec|
        JSON::Any.new({"codec_name" => JSON::Any.new(codec)})
      end
      return CrDlp::ProcessResult.new(
        0,
        JSON::Any.new({"streams" => JSON::Any.new(streams)}).to_json,
        "",
      )
    end
    concat_path = arguments[arguments.index("-i").not_nil! + 1]
    inputs = File.read_lines(concat_path).compact_map do |line|
      next unless line.starts_with?("file 'file:")
      line["file 'file:".size...-1]
    end
    File.write(arguments.last, inputs.join { |path| File.read(path) })
    CrDlp::ProcessResult.new(0, "", "")
  end
end

private class ConcatPlaylistExtractor < CrDlp::Extractor
  def key : String
    "ConcatPlaylist"
  end

  def name : String
    "concat_playlist"
  end

  def suitable?(url : String) : Bool
    url == "concat:playlist"
  end

  def extract(url : String) : CrDlp::Info
    info = base_info("playlist", "Playlist", url)
    info["_type"] = "multi_video"
    info["entries"] = JSON::Any.new(%w[first second].map do |id|
      JSON::Any.new({
        "id"           => JSON::Any.new(id),
        "title"        => JSON::Any.new(id),
        "url"          => JSON::Any.new("fixture://#{id}"),
        "protocol"     => JSON::Any.new("fixture"),
        "ext"          => JSON::Any.new("mp4"),
        "fixture_data" => JSON::Any.new(id.upcase),
      })
    end)
    info
  end
end

private def concat_playlist_info(paths : Array(String), type = "playlist") : CrDlp::Info
  entries = paths.map do |path|
    JSON::Any.new({
      "id"                  => JSON::Any.new(Path.new(path).stem),
      "ext"                 => JSON::Any.new("mp4"),
      "requested_downloads" => JSON::Any.new([
        JSON::Any.new({
          "filepath" => JSON::Any.new(path),
          "ext"      => JSON::Any.new("mp4"),
        }),
      ]),
    })
  end
  CrDlp::Info.new({
    "_type"   => JSON::Any.new(type),
    "id"      => JSON::Any.new("playlist"),
    "title"   => JSON::Any.new("Playlist"),
    "entries" => JSON::Any.new(entries),
  })
end

describe CrDlp::FFmpegConcatPostProcessor do
  it "concatenates compatible entries and records the final download" do
    directory = File.join(Dir.tempdir, "cr-dlp-concat-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      first = File.join(directory, "first.mp4")
      second = File.join(directory, "second.mp4")
      File.write(first, "ONE")
      File.write(second, "TWO")
      runner = ConcatRunner.new(
        probe_signatures: [%w[h264 aac], %w[h264 aac]],
      )
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "pl_video" => JSON::Any.new("joined.%(ext)s"),
        }),
        "paths" => JSON::Any.new({
          "pl_video" => JSON::Any.new(directory),
        }),
      })
      client = CrDlp::Client.new(options, process_runner: runner, auto_init: false)
      info = concat_playlist_info([first, second])

      CrDlp::FFmpegConcatPostProcessor.new(client).run(info)

      destination = File.join(directory, "joined.mp4")
      File.read(destination).should eq("ONETWO")
      File.exists?(first).should be_false
      File.exists?(second).should be_false
      info.string?("filepath").should eq(destination)
      info.array?("requested_downloads").not_nil!.first.as_h["filepath"].as_s
        .should eq(destination)
      runner.calls.count { |command, _| command.includes?("ffprobe") }.should eq(2)
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "rejects incompatible streams and preserves inputs" do
    directory = File.join(Dir.tempdir, "cr-dlp-concat-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      first = File.join(directory, "first.mp4")
      second = File.join(directory, "second.mp4")
      File.write(first, "ONE")
      File.write(second, "TWO")
      runner = ConcatRunner.new(
        probe_signatures: [%w[h264 aac], %w[vp9 opus]],
      )
      client = CrDlp::Client.new(
        CrDlp::ParsedOptions.new({
          "paths" => JSON::Any.new({"home" => JSON::Any.new(directory)}),
        }),
        process_runner: runner,
        auto_init: false,
      )

      expect_raises(CrDlp::PostProcessingError, "different streams/codecs") do
        CrDlp::FFmpegConcatPostProcessor.new(client)
          .run(concat_playlist_info([first, second]))
      end
      File.read(first).should eq("ONE")
      File.read(second).should eq("TWO")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "preserves inputs when ffmpeg fails" do
    directory = File.join(Dir.tempdir, "cr-dlp-concat-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      first = File.join(directory, "first.mp4")
      second = File.join(directory, "second.mp4")
      File.write(first, "ONE")
      File.write(second, "TWO")
      client = CrDlp::Client.new(
        CrDlp::ParsedOptions.new({
          "paths" => JSON::Any.new({"home" => JSON::Any.new(directory)}),
        }),
        process_runner: ConcatRunner.new(succeeds: false),
        auto_init: false,
      )

      expect_raises(CrDlp::PostProcessingError, "concat failed") do
        CrDlp::FFmpegConcatPostProcessor.new(client)
          .run(concat_playlist_info([first, second]))
      end
      File.read(first).should eq("ONE")
      File.read(second).should eq("TWO")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "concatenates real compatible media with ffmpeg" do
    ffmpeg = Process.find_executable("ffmpeg")
    ffprobe = Process.find_executable("ffprobe")
    pending!("ffmpeg and ffprobe are required") unless ffmpeg && ffprobe

    directory = File.join(Dir.tempdir, "cr-dlp-real-concat-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      inputs = [440, 660].map_with_index do |frequency, index|
        path = File.join(directory, "#{index}.m4a")
        Process.run(
          ffmpeg,
          [
            "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", "sine=frequency=#{frequency}:duration=0.5",
            "-c:a", "aac", path,
          ],
        ).success?.should be_true
        path
      end
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "pl_video" => JSON::Any.new("joined.%(ext)s"),
        }),
        "paths" => JSON::Any.new({"pl_video" => JSON::Any.new(directory)}),
      })
      client = CrDlp::Client.new(options, auto_init: false)
      info = concat_playlist_info(inputs)
      info.array?("entries").not_nil!.each do |entry|
        entry.as_h["ext"] = JSON::Any.new("m4a")
        entry.as_h["requested_downloads"].as_a.first.as_h["ext"] = JSON::Any.new("m4a")
      end

      CrDlp::FFmpegConcatPostProcessor.new(client).run(info)

      output = File.join(directory, "joined.m4a")
      File.size(output).should be > 0
      probe_output = IO::Memory.new
      Process.run(
        ffprobe,
        [
          "-v", "error", "-show_entries", "format=duration",
          "-of", "default=nw=1:nk=1", output,
        ],
        output: probe_output,
      ).success?.should be_true
      probe_output.to_s.strip.to_f.should be_close(1.0, 0.2)
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "runs automatically for multi-video results and consumes final download descriptors" do
    directory = File.join(Dir.tempdir, "cr-dlp-concat-pipeline-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      runner = ConcatRunner.new
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default"  => JSON::Any.new("%(id)s.%(ext)s"),
          "pl_video" => JSON::Any.new("joined.%(ext)s"),
        }),
        "paths" => JSON::Any.new({
          "home"     => JSON::Any.new(directory),
          "pl_video" => JSON::Any.new(directory),
        }),
        "concat_playlist" => JSON::Any.new("multi_video"),
        "fixup"           => JSON::Any.new("never"),
      })
      client = CrDlp::Client.new(options, process_runner: runner)
      client.extractor_registry.prepend("ConcatPlaylist", "concat_playlist") do |instance|
        ConcatPlaylistExtractor.new(instance)
      end

      playlist = client.extract_info("concat:playlist")

      output = File.join(directory, "joined.mp4")
      File.read(output).should eq("FIRSTSECOND")
      playlist.string?("filepath").should eq(output)
      playlist.array?("requested_downloads").not_nil!.first.as_h["filepath"].as_s
        .should eq(output)
      File.exists?(File.join(directory, "first.mp4")).should be_false
      File.exists?(File.join(directory, "second.mp4")).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
