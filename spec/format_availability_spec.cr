require "./spec_helper"

private class AvailabilityFixtureExtractor < CrDlp::Extractor
  def initialize(client : CrDlp::Client, @base_url : String, @mode = "http")
    super(client)
  end

  def key : String
    "AvailabilityFixture"
  end

  def name : String
    "availability-fixture"
  end

  def suitable?(url : String) : Bool
    url == "availability:fixture"
  end

  def extract(url : String) : CrDlp::Info
    info = base_info("availability", "availability", url)
    if @mode == "hls"
      info["url"] = "#{@base_url}/media.m3u8"
      info["protocol"] = "m3u8_native"
      info["ext"] = "mp4"
      info["formats"] = JSON::Any.new([
        JSON::Any.new({
          "format_id" => JSON::Any.new("hls"),
          "url"       => JSON::Any.new("#{@base_url}/media.m3u8"),
          "protocol"  => JSON::Any.new("m3u8_native"),
          "ext"       => JSON::Any.new("mp4"),
          "vcodec"    => JSON::Any.new("h264"),
          "acodec"    => JSON::Any.new("aac"),
        }),
      ])
      return info
    end

    info["url"] = "#{@base_url}/high.mp4"
    info["protocol"] = "http"
    info["ext"] = "mp4"
    info["formats"] = JSON::Any.new([
      format("low", "#{@base_url}/low.mp4", 360),
      format("high", "#{@base_url}/high.mp4", 1080, needs_testing: @mode == "marked"),
    ])
    info
  end

  private def format(
    id : String,
    url : String,
    height : Int32,
    needs_testing = false,
  ) : JSON::Any
    values = {
      "format_id"    => JSON::Any.new(id),
      "url"          => JSON::Any.new(url),
      "protocol"     => JSON::Any.new("http"),
      "ext"          => JSON::Any.new("mp4"),
      "vcodec"       => JSON::Any.new("h264"),
      "acodec"       => JSON::Any.new("aac"),
      "height"       => JSON::Any.new(height.to_i64),
      "http_headers" => JSON::Any.new({
        "X-Format-Probe" => JSON::Any.new(id),
      }),
    }
    values["__needs_testing"] = JSON::Any.new(true) if needs_testing
    JSON::Any.new(values)
  end
end

private def availability_client(
  options : CrDlp::ParsedOptions,
  base_url : String,
  mode = "http",
) : CrDlp::Client
  client = CrDlp::Client.new(options)
  client.extractor_registry.prepend("AvailabilityFixture", "availability-fixture") do |instance|
    AvailabilityFixtureExtractor.new(instance, base_url, mode)
  end
  client
end

describe "format availability probing" do
  it "lazily skips a broken best format and falls back to the next candidate" do
    requests = [] of Tuple(String, String?, String?)
    server = HTTP::Server.new do |context|
      requests << {
        context.request.path,
        context.request.headers["Range"]?,
        context.request.headers["X-Format-Probe"]?,
      }
      if context.request.path == "/high.mp4"
        context.response.status = HTTP::Status::NOT_FOUND
      else
        context.response.status = HTTP::Status::PARTIAL_CONTENT
        context.response.print("L")
      end
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      options = CrDlp::ParsedOptions.new({
        "check_formats" => JSON::Any.new("selected"),
      })
      info = availability_client(
        options,
        "http://127.0.0.1:#{address.port}",
      ).extract_info("availability:fixture", download: false)

      info.string?("format_id").should eq("low")
      requests.map(&.[0]).should eq(["/high.mp4", "/low.mp4"])
      requests.map(&.[1]).should eq(["bytes=0-1023", "bytes=0-1023"])
      requests.map(&.[2]).should eq(["high", "low"])
    ensure
      server.close
    end
  end

  it "checks every format before selection with --check-all-formats" do
    requests = [] of String
    server = HTTP::Server.new do |context|
      requests << context.request.path
      if context.request.path == "/high.mp4"
        context.response.status = HTTP::Status::NOT_FOUND
      else
        context.response.status = HTTP::Status::PARTIAL_CONTENT
        context.response.print("L")
      end
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      options = CrDlp::ParsedOptions.new({
        "check_formats" => JSON::Any.new(true),
        "format"        => JSON::Any.new("low"),
      })
      info = availability_client(
        options,
        "http://127.0.0.1:#{address.port}",
      ).extract_info("availability:fixture", download: false)

      info.string?("format_id").should eq("low")
      info.formats.map { |format| format.as_h["format_id"].as_s }.should eq(["low"])
      requests.sort.should eq(["/high.mp4", "/low.mp4"])
    ensure
      server.close
    end
  end

  it "checks only extractor-marked risky formats by default" do
    requests = [] of String
    server = HTTP::Server.new do |context|
      requests << context.request.path
      context.response.status = HTTP::Status::NOT_FOUND
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      info = availability_client(
        CrDlp::ParsedOptions.new,
        "http://127.0.0.1:#{address.port}",
        "marked",
      ).extract_info("availability:fixture", download: false)

      info.string?("format_id").should eq("low")
      requests.should eq(["/high.mp4"])
    ensure
      server.close
    end
  end

  it "does not make probe requests when checks are disabled" do
    options = CrDlp::ParsedOptions.new({
      "check_formats" => JSON::Any.new(false),
    })
    info = availability_client(
      options,
      "http://127.0.0.1:1",
    ).extract_info("availability:fixture", download: false)

    info.string?("format_id").should eq("high")
  end

  it "tests the first HLS media fragment instead of stopping at the manifest" do
    requests = [] of String
    ranges = [] of String?
    server = HTTP::Server.new do |context|
      requests << context.request.path
      ranges << context.request.headers["Range"]?
      case context.request.path
      when "/media.m3u8"
        context.response.print("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n")
      when "/segment.ts"
        context.response.status = HTTP::Status::PARTIAL_CONTENT
        context.response.print("T")
      else
        context.response.status = HTTP::Status::NOT_FOUND
      end
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      options = CrDlp::ParsedOptions.new({
        "check_formats" => JSON::Any.new("selected"),
      })
      info = availability_client(
        options,
        "http://127.0.0.1:#{address.port}",
        "hls",
      ).extract_info("availability:fixture", download: false)

      info.string?("format_id").should eq("hls")
      requests.should eq(["/media.m3u8", "/segment.ts"])
      ranges.should eq([nil, "bytes=0-1023"])
    ensure
      server.close
    end
  end

  it "probes the first DASH fragment with its byte range" do
    received_range = Channel(String?).new(1)
    server = HTTP::Server.new do |context|
      received_range.send(context.request.headers["Range"]?)
      context.response.status = HTTP::Status::PARTIAL_CONTENT
      context.response.print("D")
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      info = CrDlp::Info.new({
        "id"    => JSON::Any.new("dash"),
        "title" => JSON::Any.new("dash"),
      })
      format = {
        "format_id" => JSON::Any.new("dash"),
        "protocol"  => JSON::Any.new("http_dash_segments"),
        "url"       => JSON::Any.new("http://127.0.0.1:#{address.port}/manifest.mpd"),
        "fragments" => JSON::Any.new([
          JSON::Any.new({
            "url"   => JSON::Any.new("http://127.0.0.1:#{address.port}/segment.m4s"),
            "range" => JSON::Any.new("10-19"),
          }),
        ]),
      }

      CrDlp::FormatAvailabilityProbe.new(
        CrDlp::Client.new,
        info,
      ).working?(format).should be_true
      received_range.receive.should eq("bytes=10-19")
    ensure
      server.close
    end
  end
end
