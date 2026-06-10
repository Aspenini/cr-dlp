require "./spec_helper"
require "http/server"

private def with_dash_server(&block : String ->)
  range_requests = Atomic(Int32).new(0)
  dynamic_requests = Atomic(Int32).new(0)
  server = HTTP::Server.new do |context|
    case context.request.path
    when "/manifest.mpd"
      context.response.content_type = "application/dash+xml"
      context.response.print <<-'MPD'
        <?xml version="1.0"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT2S">
          <Period>
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1.4d401e">
              <Representation id="low" bandwidth="100000" width="320" height="180">
                <SegmentList>
                  <Initialization sourceURL="low-init.mp4"/>
                  <SegmentURL media="low.m4s"/>
                </SegmentList>
              </Representation>
              <Representation id="high" bandwidth="200000" width="640" height="360">
                <SegmentList>
                  <Initialization sourceURL="media.bin" range="0-3"/>
                  <SegmentURL media="one.m4s"/>
                  <SegmentURL media="two.m4s"/>
                </SegmentList>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        MPD
    when "/dynamic.mpd"
      request = dynamic_requests.add(1)
      if request == 0
        context.response.print <<-'MPD'
          <?xml version="1.0"?>
          <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="dynamic" minimumUpdatePeriod="PT0.05S">
            <Period>
              <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1.4d401e">
                <Representation id="live" bandwidth="200000" width="640" height="360">
                  <SegmentTemplate initialization="init.mp4" media="$Number$.m4s" startNumber="1">
                    <SegmentTimeline><S t="0" d="1"/></SegmentTimeline>
                  </SegmentTemplate>
                </Representation>
              </AdaptationSet>
            </Period>
          </MPD>
          MPD
      else
        context.response.print <<-'MPD'
          <?xml version="1.0"?>
          <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT2S">
            <Period>
              <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1.4d401e">
                <Representation id="live" bandwidth="200000" width="640" height="360">
                  <SegmentTemplate initialization="init.mp4" media="$Number$.m4s" startNumber="1">
                    <SegmentTimeline><S t="0" d="1" r="1"/></SegmentTimeline>
                  </SegmentTemplate>
                </Representation>
              </AdaptationSet>
            </Period>
          </MPD>
          MPD
      end
    when "/media.bin"
      range_requests.add(1)
      context.response.write("INIT-data".to_slice[0, 4])
    when "/one.m4s"
      context.response.write("ONE".to_slice)
    when "/two.m4s"
      context.response.write("TWO".to_slice)
    when "/init.mp4"
      range_requests.add(1)
      context.response.write("INIT".to_slice)
    when "/1.m4s"
      context.response.write("ONE".to_slice)
    when "/2.m4s"
      context.response.write("TWO".to_slice)
    when "/low-init.mp4"
      context.response.write("LOWI".to_slice)
    when "/low.m4s"
      context.response.write("LOW".to_slice)
    else
      context.response.status = HTTP::Status::NOT_FOUND
    end
  end
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  begin
    yield "http://127.0.0.1:#{address.port}"
    range_requests.get.should be > 0
  ensure
    server.close
  end
end

describe CrDlp::Manifest::Dash do
  it "parses duration templates from the upstream fixture" do
    presentation = CrDlp::Manifest::Dash::Parser.parse(
      File.read("test/testdata/mpd/float_duration.mpd"),
      "https://example.test/path/manifest.mpd",
    )

    presentation.formats.size.should eq(7)
    audio = presentation.formats.find { |format| format.id == "318597" && !format.video? }.not_nil!
    audio.ext.should eq("m4a")
    audio.fragments.size.should eq(3008)
    audio.fragments.first.url.should eq("https://example.test/path/ai_318597.mp4d")
    audio.fragments.last.url.should eq("https://example.test/path/a_318597_3006.mp4d")
    presentation.best_representation.not_nil!.height.should eq(1080)
  end

  it "parses explicit segment lists and direct SegmentBase representations" do
    listed = CrDlp::Manifest::Dash::Parser.parse(
      File.read("test/testdata/mpd/urls_only.mpd"),
      "https://example.test/path/manifest.mpd",
    )
    listed.formats.size.should eq(7)
    listed.formats.each { |format| format.fragments.size.should eq(26) }
    listed.formats.first.fragments.first.url.should contain("/vd_")

    direct = CrDlp::Manifest::Dash::Parser.parse(
      File.read("test/testdata/mpd/unfragmented.mpd"),
      "https://example.test/path/manifest.mpd",
    )
    direct.formats.size.should eq(3)
    direct.formats.each(&.fragmented?.should(be_false))
    direct.formats.map(&.url).should eq([
      "https://example.test/path/DASH_360",
      "https://example.test/path/DASH_240",
      "https://example.test/path/audio",
    ])
  end

  it "separates subtitle representations and expands timelines" do
    presentation = CrDlp::Manifest::Dash::Parser.parse(
      File.read("test/testdata/mpd/subtitles.mpd"),
      "https://example.test/path/manifest.mpd",
    )

    presentation.formats.size.should eq(6)
    presentation.subtitles.keys.should eq(["en"])
    subtitle = presentation.representations.find(&.subtitle?).not_nil!
    subtitle.fragments.size.should eq(12)
    subtitle.fragments[1].url.should end_with("textstream_eng=1000-0.dash")
  end

  it "extracts the best representation and assembles its fragments" do
    with_dash_server do |base_url|
      directory = File.join(Dir.tempdir, "cr-dlp-dash-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      begin
        output = File.join(directory, "%(id)s.%(ext)s")
        options = CrDlp::ParsedOptions.new({
          "outtmpl" => JSON::Any.new({"default" => JSON::Any.new(output)}),
        })
        info = CrDlp::Client.new(options).extract_info("#{base_url}/manifest.mpd")

        info.string?("format_id").should eq("high")
        info.int?("height").should eq(360)
        info.string?("protocol").should eq("http_dash_segments")
        File.read(File.join(directory, "manifest.mp4")).should eq("INITONETWO")

        low_options = CrDlp::ParsedOptions.new({"format" => JSON::Any.new("low")})
        low = CrDlp::Client.new(low_options).extract_info("#{base_url}/manifest.mpd", download: false)
        low.string?("format_id").should eq("low")
        low.array?("fragments").not_nil!.size.should eq(2)
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end

  it "expands duration-based dynamic availability windows" do
    presentation = CrDlp::Manifest::Dash::Parser.parse(<<-'MPD', "https://example.test/live/manifest.mpd")
      <?xml version="1.0"?>
      <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
           type="dynamic"
           availabilityStartTime="2026-01-01T00:00:00Z"
           publishTime="2026-01-01T00:00:10Z"
           timeShiftBufferDepth="PT2S"
           minimumUpdatePeriod="PT1S">
        <Period>
          <AdaptationSet contentType="video" mimeType="video/mp4">
            <Representation id="live">
              <SegmentTemplate initialization="init.mp4" media="$Number$-$Time$.m4s"
                               startNumber="1" duration="1" timescale="1"/>
            </Representation>
          </AdaptationSet>
        </Period>
      </MPD>
      MPD

    presentation.dynamic.should be_true
    presentation.minimum_update_period.should eq(1.0)
    representation = presentation.formats.first
    representation.dynamic.should be_true
    representation.fragments.map(&.url).should eq([
      "https://example.test/live/init.mp4",
      "https://example.test/live/9-8.m4s",
      "https://example.test/live/10-9.m4s",
    ])
  end

  it "refreshes dynamic manifests and deduplicates the selected representation" do
    with_dash_server do |base_url|
      directory = File.join(Dir.tempdir, "cr-dlp-dash-live-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      begin
        options = CrDlp::ParsedOptions.new({
          "outtmpl" => JSON::Any.new({
            "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
          }),
          "fixup" => JSON::Any.new("never"),
        })
        info = CrDlp::Client.new(options).extract_info("#{base_url}/dynamic.mpd")

        info.bool?("is_live").should be_true
        File.read(File.join(directory, "dynamic.mp4")).should eq("INITONETWO")
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end
end
