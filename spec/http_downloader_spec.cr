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
    CrDlp::Networking::Response.new(request.url, 206, {
      "Content-Length" => bytes.size.to_s,
    }, Bytes.empty)
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
end
