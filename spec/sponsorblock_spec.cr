require "./spec_helper"
require "http/server"

private class SponsorChapterRunner < CrDlp::ProcessRunner
  def executable_available?(command : String) : Bool
    !command.includes?("ffprobe")
  end

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    File.write(arguments.last, "CUT")
    CrDlp::ProcessResult.new(0, "", "")
  end
end

private def sponsor_info(id : String, duration = 100.0) : CrDlp::Info
  CrDlp::Info.new({
    "id"            => JSON::Any.new(id),
    "title"         => JSON::Any.new("Sponsor fixture"),
    "url"           => JSON::Any.new("fixture://sponsor"),
    "protocol"      => JSON::Any.new("fixture"),
    "ext"           => JSON::Any.new("mp4"),
    "extractor_key" => JSON::Any.new("Youtube"),
    "duration"      => JSON::Any.new(duration),
  })
end

describe CrDlp::SponsorBlockPostProcessor do
  it "fetches, filters, and normalizes SponsorBlock segments" do
    video_id = "sponsor-video"
    requested_path = Channel(String).new(1)
    server = HTTP::Server.new do |context|
      requested_path.send(context.request.resource)
      context.response.content_type = "application/json"
      context.response.print([
        {
          "videoID"  => video_id,
          "segments" => [
            {
              "segment"       => [0.5, 10.0],
              "category"      => "sponsor",
              "actionType"    => "skip",
              "videoDuration" => 100.0,
            },
            {
              "segment"       => [20.0, 20.1],
              "category"      => "poi_highlight",
              "actionType"    => "poi",
              "videoDuration" => 100.0,
            },
            {
              "segment"       => [30.0, 40.0],
              "category"      => "chapter",
              "description"   => "Custom chapter",
              "actionType"    => "chapter",
              "videoDuration" => 100.0,
            },
            {
              "segment"       => [90.0, 99.5],
              "category"      => "outro",
              "actionType"    => "skip",
              "videoDuration" => 100.0,
            },
            {
              "segment"       => [50.0, 60.0],
              "category"      => "intro",
              "actionType"    => "skip",
              "videoDuration" => 80.0,
            },
          ],
        },
      ].to_json)
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      options = CrDlp::ParsedOptions.new({
        "sponsorblock_mark" => JSON::Any.new(%w[
          sponsor poi_highlight chapter outro intro
        ].map { |value| JSON::Any.new(value) }),
        "sponsorblock_api" => JSON::Any.new("http://127.0.0.1:#{address.port}"),
      })
      client = CrDlp::Client.new(options)
      info = sponsor_info(video_id)

      CrDlp::SponsorBlockPostProcessor.new(client).run(info)

      resource = requested_path.receive
      resource.should start_with("/api/skipSegments/#{Digest::SHA256.hexdigest(video_id)[0, 4]}?")
      params = URI::Params.parse(resource.partition('?')[2])
      params["service"].should eq("YouTube")
      JSON.parse(params["categories"]).as_a.map(&.as_s).should eq(
        %w[sponsor poi_highlight chapter outro intro],
      )

      chapters = info.array?("sponsorblock_chapters").not_nil!
      chapters.size.should eq(4)
      chapters[0].as_h["start_time"].as_f.should eq(0)
      chapters[1].as_h["end_time"].as_f.should eq(21.1)
      chapters[2].as_h["title"].as_s.should eq("Custom chapter")
      chapters[3].as_h["end_time"].as_f.should eq(100)
    ensure
      server.close
    end
  end

  it "returns no segments on a 404 and skips unsupported extractors" do
    server = HTTP::Server.new do |context|
      context.response.status_code = 404
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      options = CrDlp::ParsedOptions.new({
        "sponsorblock_mark" => JSON::Any.new([JSON::Any.new("sponsor")]),
        "sponsorblock_api"  => JSON::Any.new("http://127.0.0.1:#{address.port}"),
      })
      client = CrDlp::Client.new(options)
      info = sponsor_info("missing")
      CrDlp::SponsorBlockPostProcessor.new(client).run(info)
      info.array?("sponsorblock_chapters").not_nil!.should be_empty

      unsupported = sponsor_info("other")
      unsupported["extractor_key"] = "Generic"
      CrDlp::SponsorBlockPostProcessor.new(client).run(unsupported)
      unsupported.array?("sponsorblock_chapters").should be_nil
    ensure
      server.close
    end
  end

  it "feeds fetched removals into chapter cutting" do
    video_id = "remove-video"
    server = HTTP::Server.new do |context|
      context.response.content_type = "application/json"
      context.response.print([
        {
          "videoID"  => video_id,
          "segments" => [
            {
              "segment"       => [10.0, 20.0],
              "category"      => "sponsor",
              "actionType"    => "skip",
              "videoDuration" => 30.0,
            },
          ],
        },
      ].to_json)
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    directory = File.join(Dir.tempdir, "cr-dlp-sponsor-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      media = File.join(directory, "media.mp4")
      File.write(media, "MEDIA")
      runner = SponsorChapterRunner.new
      options = CrDlp::ParsedOptions.new({
        "sponsorblock_remove" => JSON::Any.new([JSON::Any.new("sponsor")]),
        "sponsorblock_api"    => JSON::Any.new("http://127.0.0.1:#{address.port}"),
      })
      client = CrDlp::Client.new(options, process_runner: runner)
      info = sponsor_info(video_id, 30)
      info["filepath"] = media
      info["chapters"] = JSON::Any.new([
        JSON::Any.new({
          "start_time" => JSON::Any.new(0.0),
          "end_time"   => JSON::Any.new(30.0),
          "title"      => JSON::Any.new("Whole"),
        }),
      ])

      CrDlp::SponsorBlockPostProcessor.new(client).run(info)
      CrDlp::ModifyChaptersPostProcessor.new(client).run(info)

      File.read(media).should eq("CUT")
      info.float?("duration").should eq(20)
    ensure
      server.close
      FileUtils.rm_rf(directory)
    end
  end
end
