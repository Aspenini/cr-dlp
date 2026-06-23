require "./spec_helper"

private class InterruptedDownloadHandler < CrDlp::Networking::RequestHandler
  getter calls = 0

  def key : String
    "InterruptedFixture"
  end

  def supports?(request : CrDlp::Networking::Request) : Bool
    request.url == "https://download.test/video.mp4"
  end

  def send(request : CrDlp::Networking::Request) : CrDlp::Networking::Response
    CrDlp::Networking::Response.new(request.url, 200, {} of String => String, "ABCDEFGHIJ".to_slice)
  end

  def download(
    request : CrDlp::Networking::Request,
    destination : IO,
    progress : Proc(Int64, Int64?, Nil)? = nil,
  ) : CrDlp::Networking::Response
    @calls += 1
    if @calls == 1
      destination.write("ABCD".to_slice)
      progress.try(&.call(4_i64, 10_i64))
      raise IO::Error.new("planned interruption")
    end
    request.headers["Range"]?.should eq("bytes=4-")
    destination.write("EFGHIJ".to_slice)
    progress.try(&.call(6_i64, 6_i64))
    CrDlp::Networking::Response.new(request.url, 206, {
      "Content-Length" => "6",
      "Content-Range"  => "bytes 4-9/10",
    }, Bytes.empty)
  end
end

private class TestRangeHandler < CrDlp::Networking::RequestHandler
  getter range : String?

  def key : String
    "TestRangeFixture"
  end

  def supports?(request : CrDlp::Networking::Request) : Bool
    request.url == "https://download.test/large.mp4"
  end

  def send(request : CrDlp::Networking::Request) : CrDlp::Networking::Response
    raise "not used"
  end

  def download(
    request : CrDlp::Networking::Request,
    destination : IO,
    progress : Proc(Int64, Int64?, Nil)? = nil,
  ) : CrDlp::Networking::Response
    @range = request.headers["Range"]?
    bytes = Bytes.new(10_241, 65_u8)
    destination.write(bytes)
    progress.try(&.call(bytes.size.to_i64, bytes.size.to_i64))
    CrDlp::Networking::Response.new(request.url, 206, {
      "Content-Length" => bytes.size.to_s,
    }, Bytes.empty)
  end
end

private class ChunkedDownloadHandler < CrDlp::Networking::RequestHandler
  DATA = "ABCDEFGHIJ"

  getter ranges = [] of String

  def key : String
    "ChunkedFixture"
  end

  def supports?(request : CrDlp::Networking::Request) : Bool
    request.url == "https://download.test/chunked.mp4"
  end

  def send(request : CrDlp::Networking::Request) : CrDlp::Networking::Response
    raise "not used"
  end

  def download(
    request : CrDlp::Networking::Request,
    destination : IO,
    progress : Proc(Int64, Int64?, Nil)? = nil,
  ) : CrDlp::Networking::Response
    range = request.headers["Range"]? || "bytes=0-"
    @ranges << range
    match = range.match(/\Abytes=(\d+)-(\d+)?\z/) || raise "invalid range #{range}"
    start = match[1].to_i
    requested_end = match[2]?.try(&.to_i) || (DATA.bytesize - 1)
    finish = Math.min(requested_end, DATA.bytesize - 1)
    bytes = start <= finish ? DATA.to_slice[start, finish - start + 1] : Bytes.empty
    destination.write(bytes)
    progress.try(&.call(bytes.size.to_i64, bytes.size.to_i64))
    CrDlp::Networking::Response.new(request.url, 206, {
      "Content-Length" => bytes.size.to_s,
      "Content-Range"  => "bytes #{start}-#{finish}/#{DATA.bytesize}",
      "Last-Modified"  => "Wed, 21 Oct 2015 07:28:00 GMT",
    }, Bytes.empty)
  end
end

private class ExternalDownloadRunner < CrDlp::ProcessRunner
  getter command : String?
  getter arguments = [] of String

  def initialize(@available = true, @exit_code = 0)
  end

  def executable_available?(command : String) : Bool
    @available
  end

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    @command = command
    @arguments = arguments
    if @exit_code == 0
      if output = output_path(arguments)
        File.write(output, "external\n")
      end
    end
    CrDlp::ProcessResult.new(@exit_code, "", @exit_code == 0 ? "" : "planned failure")
  end

  private def output_path(arguments : Array(String)) : String?
    arguments.each_with_index do |argument, index|
      if argument.in?("-o", "-O", "--output", "--output-document")
        return arguments[index + 1]?
      end
    end
    directory = nil.as(String?)
    basename = nil.as(String?)
    arguments.each_with_index do |argument, index|
      directory = arguments[index + 1]? if argument == "-d"
      basename = arguments[index + 1]? if argument == "-o"
    end
    directory && basename ? File.join(directory, basename) : nil
  end
end

describe CrDlp::HttpDownloader do
  it "streams to a part file and resumes after an interrupted request" do
    directory = File.join(Dir.tempdir, "cr-dlp-http-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      handler = InterruptedDownloadHandler.new
      director = CrDlp::Networking::RequestDirector.new([handler] of CrDlp::Networking::RequestHandler)
      options = CrDlp::ParsedOptions.new({
        "outtmpl"     => JSON::Any.new({"default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s"))}),
        "retries"     => JSON::Any.new("1"),
        "continue_dl" => JSON::Any.new(true),
      })
      info = CrDlp::Client.new(options, request_director: director)
        .extract_info("https://download.test/video.mp4")

      File.read(File.join(directory, "video.mp4")).should eq("ABCDEFGHIJ")
      File.exists?(File.join(directory, "video.mp4.part")).should be_false
      info.string?("filepath").should eq(File.join(directory, "video.mp4"))
      handler.calls.should eq(2)
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "uses request sleep and retry-sleep policies around HTTP downloads" do
    directory = File.join(Dir.tempdir, "cr-dlp-http-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      handler = InterruptedDownloadHandler.new
      director = CrDlp::Networking::RequestDirector.new([handler] of CrDlp::Networking::RequestHandler)
      sleeps = [] of Time::Span
      parsed = CrDlp::ArgumentParser.new.parse([
        "--sleep-requests", "0.25",
        "--retry-sleep", "http:0.5",
        "--retries", "1",
        "-o", File.join(directory, "%(id)s.%(ext)s"),
        "https://download.test/video.mp4",
      ])
      CrDlp::Client.new(
        parsed,
        request_director: director,
        sleeper: ->(span : Time::Span) { sleeps << span },
      ).download(parsed.urls).should eq(0)

      handler.calls.should eq(2)
      sleeps.map(&.total_seconds).should contain(0.25)
      sleeps.map(&.total_seconds).should contain(0.5)
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "renders progress templates and honors --no-progress" do
    directory = File.join(Dir.tempdir, "cr-dlp-http-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      handler = TestRangeHandler.new
      director = CrDlp::Networking::RequestDirector.new([handler] of CrDlp::Networking::RequestHandler)
      error = IO::Memory.new
      parsed = CrDlp::ArgumentParser.new.parse([
        "--newline",
        "--progress-template", "download:%(progress.status)s %(progress.downloaded_bytes)s/%(progress.total_bytes)s",
        "-o", File.join(directory, "%(id)s.%(ext)s"),
        "https://download.test/large.mp4",
      ])
      CrDlp::Client.new(parsed, request_director: director, error: error).download(parsed.urls).should eq(0)
      error.to_s.should contain("downloading 10241/10241")

      error = IO::Memory.new
      parsed = CrDlp::ArgumentParser.new.parse([
        "--no-progress",
        "--progress-template", "download:%(progress.status)s",
        "-o", File.join(directory, "quiet-%(id)s.%(ext)s"),
        "https://download.test/large.mp4",
      ])
      CrDlp::Client.new(parsed, request_director: director, error: error).download(parsed.urls).should eq(0)
      error.to_s.should eq("")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "uses a bounded range for direct --test downloads" do
    directory = File.join(Dir.tempdir, "cr-dlp-http-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      handler = TestRangeHandler.new
      director = CrDlp::Networking::RequestDirector.new([handler] of CrDlp::Networking::RequestHandler)
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({"default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s"))}),
        "test"    => JSON::Any.new(true),
      })
      CrDlp::Client.new(options, request_director: director)
        .extract_info("https://download.test/large.mp4")

      handler.range.should eq("bytes=0-10240")
      File.size(File.join(directory, "large.mp4")).should eq(10_241)
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "splits direct HTTP downloads into configured chunks and preserves mtime" do
    directory = File.join(Dir.tempdir, "cr-dlp-http-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      handler = ChunkedDownloadHandler.new
      director = CrDlp::Networking::RequestDirector.new([handler] of CrDlp::Networking::RequestHandler)
      parsed = CrDlp::ArgumentParser.new.parse([
        "--http-chunk-size", "4",
        "--mtime",
        "-o", File.join(directory, "%(id)s.%(ext)s"),
        "https://download.test/chunked.mp4",
      ])
      CrDlp::Client.new(parsed, request_director: director).download(parsed.urls).should eq(0)

      output = File.join(directory, "chunked.mp4")
      File.read(output).should eq("ABCDEFGHIJ")
      handler.ranges.should eq(["bytes=0-3", "bytes=4-7", "bytes=8-11"])
      expected = HTTP.parse_time("Wed, 21 Oct 2015 07:28:00 GMT").not_nil!
      (File.info(output).modification_time - expected).total_seconds.abs.should be < 2
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "uses protocol-specific external downloader commands and supplemental args" do
    directory = File.join(Dir.tempdir, "cr-dlp-http-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      runner = ExternalDownloadRunner.new
      parsed = CrDlp::ArgumentParser.new.parse([
        "--external-downloader", "https:curl",
        "--external-downloader-args", "curl:--compressed --header \"X-Test: yes\"",
        "-o", File.join(directory, "%(id)s.%(ext)s"),
        "https://download.test/external.mp4",
      ])
      CrDlp::Client.new(
        parsed,
        request_director: CrDlp::Networking::RequestDirector.new,
        process_runner: runner,
      ).download(parsed.urls).should eq(0)

      output = File.join(directory, "external.mp4")
      File.read(output).should eq("external\n")
      runner.command.should eq("curl")
      runner.arguments.should contain("--compressed")
      runner.arguments.should contain("X-Test: yes")
      runner.arguments.should contain("-o")
      runner.arguments.should contain(output)
      runner.arguments.last.should eq("https://download.test/external.mp4")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "allows complete custom external downloader argument templates" do
    directory = File.join(Dir.tempdir, "cr-dlp-http-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      runner = ExternalDownloadRunner.new
      parsed = CrDlp::ArgumentParser.new.parse([
        "--external-downloader", "custom-downloader",
        "--external-downloader-args", "custom-downloader:--url {url} --output {filepath}",
        "-o", File.join(directory, "%(id)s.%(ext)s"),
        "https://download.test/custom.mp4",
      ])
      CrDlp::Client.new(
        parsed,
        request_director: CrDlp::Networking::RequestDirector.new,
        process_runner: runner,
      ).download(parsed.urls).should eq(0)

      output = File.join(directory, "custom.mp4")
      File.read(output).should eq("external\n")
      runner.command.should eq("custom-downloader")
      runner.arguments.should eq(["--url", "https://download.test/custom.mp4", "--output", output])
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
