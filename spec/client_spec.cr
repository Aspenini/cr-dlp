require "./spec_helper"

private class AuthHeaderHandler < CrDlp::Networking::RequestHandler
  getter authorizations = [] of String?

  def key : String
    "AuthHeader"
  end

  def supports?(request : CrDlp::Networking::Request) : Bool
    URI.parse(request.url).host == "auth.test"
  end

  def send(request : CrDlp::Networking::Request) : CrDlp::Networking::Response
    @authorizations << request.headers["Authorization"]?
    CrDlp::Networking::Response.new(request.url, 200, {} of String => String, "auth".to_slice)
  end

  def download(
    request : CrDlp::Networking::Request,
    destination : IO,
    progress : Proc(Int64, Int64?, Nil)? = nil,
  ) : CrDlp::Networking::Response
    @authorizations << request.headers["Authorization"]?
    destination.write("auth".to_slice)
    progress.try(&.call(4_i64, 4_i64))
    CrDlp::Networking::Response.new(request.url, 200, {"Content-Length" => "4"}, Bytes.empty)
  end
end

private class NetrcCommandRunner < CrDlp::ProcessRunner
  def initialize(@netrc : String)
  end

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    CrDlp::ProcessResult.new(1, "", "unexpected command")
  end

  def run_shell(command : String) : CrDlp::ProcessResult
    CrDlp::ProcessResult.new(0, @netrc, "")
  end
end

describe CrDlp::Client do
  it "runs extraction, download, hooks, postprocessing, and info JSON end to end" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      output = File.join(directory, "%(id)s.%(ext)s")
      values = {
        "outtmpl"       => JSON::Any.new({"default" => JSON::Any.new(output)}),
        "writeinfojson" => JSON::Any.new(true),
      }
      options = CrDlp::ParsedOptions.new(values)
      client = CrDlp::Client.new(options)
      statuses = [] of String
      client.add_progress_hook do |event|
        statuses << event["status"].as_s
      end

      info = client.extract_info("cr-dlp:fixture:sample")
      filename = File.join(directory, "sample.txt")
      File.read(filename).should eq("fixture:sample\n")
      File.exists?(File.join(directory, "sample.info.json")).should be_true
      info.string?("filepath").should eq(filename)
      statuses.should eq(["downloading", "finished"])
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "keeps Generic as the final extractor" do
    client = CrDlp::Client.new
    client.extractor_registry.keys.last.should eq("Generic")
  end

  it "resolves and disables cache directories compatibly" do
    directory = File.join(Dir.tempdir, "cr-dlp-cache-#{Random::Secure.hex(6)}")
    options = CrDlp::ParsedOptions.new({"cachedir" => JSON::Any.new(directory)})
    CrDlp::Client.new(options).cache_directory.should eq(File.expand_path(directory))

    disabled = CrDlp::ParsedOptions.new({"cachedir" => JSON::Any.new(false)})
    CrDlp::Client.new(disabled).cache_directory.should be_nil
  end

  it "downloads from a saved info JSON without running an extractor" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      info_path = File.join(directory, "info.json")
      File.write(info_path, {
        "id"            => "loaded",
        "title"         => "Loaded",
        "url"           => "fixture://loaded",
        "webpage_url"   => "https://example.test/loaded",
        "extractor"     => "fixture",
        "extractor_key" => "Fixture",
        "protocol"      => "fixture",
        "ext"           => "txt",
        "fixture_data"  => "from info json\n",
      }.to_json)

      options = CrDlp::ParsedOptions.new({
        "load_info_filename" => JSON::Any.new(info_path),
        "outtmpl"            => JSON::Any.new({"default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s"))}),
      })
      CrDlp::Client.new(options).download([] of String).should eq(0)
      File.read(File.join(directory, "loaded.txt")).should eq("from info json\n")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "writes metadata and link sidecars during skip-download runs" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      options = CrDlp::ParsedOptions.new({
        "skip_download"    => JSON::Any.new(true),
        "writedescription" => JSON::Any.new(true),
        "writeurllink"     => JSON::Any.new(true),
        "writewebloclink"  => JSON::Any.new(true),
        "writedesktoplink" => JSON::Any.new(true),
        "writeinfojson"    => JSON::Any.new(true),
        "outtmpl"          => JSON::Any.new({"default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s"))}),
      })
      CrDlp::Client.new(options).download(["cr-dlp:fixture:sidecar"]).should eq(0)

      stem = File.join(directory, "sidecar")
      File.exists?("#{stem}.txt").should be_false
      File.exists?("#{stem}.description").should be_true
      File.read("#{stem}.url").should contain("URL=cr-dlp:fixture:sidecar")
      File.read("#{stem}.webloc").should contain("<string>cr-dlp:fixture:sidecar</string>")
      File.read("#{stem}.desktop").should contain("URL=cr-dlp:fixture:sidecar")
      JSON.parse(File.read("#{stem}.info.json"))["id"].as_s.should eq("sidecar")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "prints JSON aliases and get-id through injectable output" do
    output = IO::Memory.new
    options = CrDlp::ParsedOptions.new({"dumpjson" => JSON::Any.new(true)})
    CrDlp::Client.new(options, output: output).download(["cr-dlp:fixture:json"]).should eq(0)
    JSON.parse(output.to_s)["id"].as_s.should eq("json")

    output = IO::Memory.new
    options = CrDlp::ParsedOptions.new({"getid" => JSON::Any.new(true)})
    CrDlp::Client.new(options, output: output).download(["cr-dlp:fixture:identifier"]).should eq(0)
    output.to_s.should eq("identifier\n")
  end

  it "appends rendered print-to-file output without downloading media" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      path = File.join(directory, "titles.txt")
      parsed = CrDlp::ArgumentParser.new.parse([
        "--print-to-file", "title", path,
        "cr-dlp:fixture:printed",
      ])
      CrDlp::Client.new(parsed).download(parsed.urls).should eq(0)

      File.read(path).should eq("printed\n")
      File.exists?(File.join(directory, "printed.txt")).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "skips saved info rejected by title, view, date, and age filters" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      info_path = File.join(directory, "info.json")
      File.write(info_path, {
        "id"           => "filtered",
        "title"        => "Filtered title",
        "url"          => "fixture://filtered",
        "protocol"     => "fixture",
        "ext"          => "txt",
        "fixture_data" => "filtered\n",
        "upload_date"  => "20240102",
        "view_count"   => 10,
        "age_limit"    => 18,
      }.to_json)
      options = CrDlp::ParsedOptions.new({
        "load_info_filename" => JSON::Any.new(info_path),
        "outtmpl"            => JSON::Any.new({"default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s"))}),
        "matchtitle"         => JSON::Any.new("Filtered"),
        "rejecttitle"        => JSON::Any.new("blocked"),
        "min_views"          => JSON::Any.new(5_i64),
        "max_views"          => JSON::Any.new(20_i64),
        "dateafter"          => JSON::Any.new("20240101"),
        "datebefore"         => JSON::Any.new("20241231"),
        "age_limit"          => JSON::Any.new(17_i64),
      })
      CrDlp::Client.new(options, error: IO::Memory.new).download([] of String).should eq(0)
      File.exists?(File.join(directory, "filtered.txt")).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "applies filesize filters after format selection" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      info_path = File.join(directory, "info.json")
      File.write(info_path, {
        "id"           => "small",
        "title"        => "Small",
        "url"          => "fixture://small",
        "protocol"     => "fixture",
        "ext"          => "txt",
        "fixture_data" => "small\n",
        "filesize"     => 5,
      }.to_json)
      options = CrDlp::ParsedOptions.new({
        "load_info_filename" => JSON::Any.new(info_path),
        "outtmpl"            => JSON::Any.new({"default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s"))}),
        "min_filesize"       => JSON::Any.new("10B"),
      })
      CrDlp::Client.new(options, error: IO::Memory.new).download([] of String).should eq(0)
      File.exists?(File.join(directory, "small.txt")).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "accepts saved info when any repeated match filter expression passes" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      info_path = File.join(directory, "info.json")
      File.write(info_path, {
        "id"           => "matched",
        "title"        => "A Fine Song",
        "url"          => "fixture://matched",
        "protocol"     => "fixture",
        "ext"          => "txt",
        "fixture_data" => "matched\n",
        "duration"     => 120,
        "view_count"   => 50,
        "is_live"      => false,
        "artist"       => {"name" => "Tester"},
      }.to_json)
      options = CrDlp::ParsedOptions.new({
        "load_info_filename" => JSON::Any.new(info_path),
        "outtmpl"            => JSON::Any.new({"default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s"))}),
        "match_filter"       => JSON::Any.new([
          JSON::Any.new("duration>1000"),
          JSON::Any.new("duration>=120 & title*='Fine' & !is_live & artist.name=Tester"),
        ]),
      })
      CrDlp::Client.new(options).download([] of String).should eq(0)
      File.read(File.join(directory, "matched.txt")).should eq("matched\n")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "rejects saved info when match filters fail and supports missing-value opt in" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      info_path = File.join(directory, "info.json")
      File.write(info_path, {
        "id"           => "unmatched",
        "title"        => "Plain Video",
        "url"          => "fixture://unmatched",
        "protocol"     => "fixture",
        "ext"          => "txt",
        "fixture_data" => "unmatched\n",
        "view_count"   => 5,
      }.to_json)
      options = CrDlp::ParsedOptions.new({
        "load_info_filename" => JSON::Any.new(info_path),
        "outtmpl"            => JSON::Any.new({"default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s"))}),
        "match_filter"       => JSON::Any.new([JSON::Any.new("missing_count>?100 & title~='^Plain'")]),
      })
      CrDlp::Client.new(options).download([] of String).should eq(0)
      File.read(File.join(directory, "unmatched.txt")).should eq("unmatched\n")

      File.delete?(File.join(directory, "unmatched.txt"))
      rejecting = CrDlp::ParsedOptions.new({
        "load_info_filename" => JSON::Any.new(info_path),
        "outtmpl"            => JSON::Any.new({"default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s"))}),
        "match_filter"       => JSON::Any.new([JSON::Any.new("view_count>10 | title='Different'")]),
      })
      CrDlp::Client.new(rejecting, error: IO::Memory.new).download([] of String).should eq(0)
      File.exists?(File.join(directory, "unmatched.txt")).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "stops dispatching when max-downloads is reached" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      options = CrDlp::ParsedOptions.new({
        "max_downloads" => JSON::Any.new(1_i64),
        "outtmpl"       => JSON::Any.new({"default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s"))}),
      })
      CrDlp::Client.new(options).download(["cr-dlp:fixture:first", "cr-dlp:fixture:second"]).should eq(0)
      File.exists?(File.join(directory, "first.txt")).should be_true
      File.exists?(File.join(directory, "second.txt")).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "uses break-match-filters to stop the queue unless break-per-input is set" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      parsed = CrDlp::ArgumentParser.new.parse([
        "--break-match-filters", "title!=stop",
        "-o", File.join(directory, "%(id)s.%(ext)s"),
        "cr-dlp:fixture:stop",
        "cr-dlp:fixture:second",
      ])
      CrDlp::Client.new(parsed, error: IO::Memory.new).download(parsed.urls).should eq(0)
      File.exists?(File.join(directory, "stop.txt")).should be_false
      File.exists?(File.join(directory, "second.txt")).should be_false

      parsed = CrDlp::ArgumentParser.new.parse([
        "--break-per-input",
        "--break-match-filters", "title!=stop",
        "-o", File.join(directory, "per-%(id)s.%(ext)s"),
        "cr-dlp:fixture:stop",
        "cr-dlp:fixture:second",
      ])
      CrDlp::Client.new(parsed, error: IO::Memory.new).download(parsed.urls).should eq(0)
      File.exists?(File.join(directory, "per-stop.txt")).should be_false
      File.read(File.join(directory, "per-second.txt")).should eq("fixture:second\n")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "resets max-downloads for each input when break-per-input is enabled" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      parsed = CrDlp::ArgumentParser.new.parse([
        "--break-per-input",
        "--max-downloads", "1",
        "-o", File.join(directory, "%(id)s.%(ext)s"),
        "cr-dlp:fixture:first",
        "cr-dlp:fixture:second",
      ])
      CrDlp::Client.new(parsed).download(parsed.urls).should eq(0)
      File.read(File.join(directory, "first.txt")).should eq("fixture:first\n")
      File.read(File.join(directory, "second.txt")).should eq("fixture:second\n")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "downloads local files only when file URLs are enabled" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      source = File.join(directory, "source.txt")
      File.write(source, "local bytes\n")
      options = CrDlp::ParsedOptions.new({
        "enable_file_urls" => JSON::Any.new(true),
        "outtmpl"          => JSON::Any.new({"default" => JSON::Any.new(File.join(directory, "copy.%(ext)s"))}),
      })
      CrDlp::Client.new(options).download([source]).should eq(0)
      File.read(File.join(directory, "copy.txt")).should eq("local bytes\n")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "applies media sleep and rate limiting to local file copies" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      source = File.join(directory, "source.bin")
      File.write(source, "0123456789")
      sleeps = [] of Time::Span
      parsed = CrDlp::ArgumentParser.new.parse([
        "--enable-file-urls",
        "--sleep-interval", "0.5",
        "--buffer-size", "4B",
        "--rate-limit", "4B",
        "-o", File.join(directory, "copy.%(ext)s"),
        source,
      ])
      CrDlp::Client.new(
        parsed,
        sleeper: ->(span : Time::Span) { sleeps << span },
      ).download(parsed.urls).should eq(0)

      File.read(File.join(directory, "copy.bin")).should eq("0123456789")
      sleeps.map(&.total_seconds).should contain(0.5)
      sleeps.count { |span| span.total_seconds >= 1.0 }.should be >= 2
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "honors allowed extractors and force-generic selection" do
    denied = CrDlp::ParsedOptions.new({
      "allowed_extractors" => JSON::Any.new([JSON::Any.new("Generic")]),
    })
    CrDlp::Client.new(denied, error: IO::Memory.new)
      .download(["cr-dlp:fixture:not-allowed"]).should eq(1)

    forced = CrDlp::ParsedOptions.new({
      "force_generic_extractor" => JSON::Any.new(true),
    })
    info = CrDlp::Client.new(forced).extract_info("https://archive.org/example.mp4", download: false)
    info.string?("extractor_key").should eq("Generic")
  end

  it "honors no-playlist by processing only the first playlist entry" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      info_path = File.join(directory, "playlist.json")
      entry = ->(id : String) {
        {
          "id"            => JSON::Any.new(id),
          "title"         => JSON::Any.new(id),
          "url"           => JSON::Any.new("fixture://#{id}"),
          "protocol"      => JSON::Any.new("fixture"),
          "ext"           => JSON::Any.new("txt"),
          "fixture_data"  => JSON::Any.new("#{id}\n"),
          "extractor_key" => JSON::Any.new("Fixture"),
        }
      }
      File.write(info_path, JSON::Any.new({
        "_type"   => JSON::Any.new("playlist"),
        "id"      => JSON::Any.new("playlist"),
        "title"   => JSON::Any.new("playlist"),
        "entries" => JSON::Any.new([JSON::Any.new(entry.call("one")), JSON::Any.new(entry.call("two"))]),
      }).to_json)
      options = CrDlp::ParsedOptions.new({
        "load_info_filename" => JSON::Any.new(info_path),
        "noplaylist"         => JSON::Any.new(true),
        "outtmpl"            => JSON::Any.new({"default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s"))}),
      })
      CrDlp::Client.new(options).download([] of String).should eq(0)
      File.read(File.join(directory, "one.txt")).should eq("one\n")
      File.exists?(File.join(directory, "two.txt")).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "applies explicit username/password basic auth to requests" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      handler = AuthHeaderHandler.new
      director = CrDlp::Networking::RequestDirector.new([handler] of CrDlp::Networking::RequestHandler)
      parsed = CrDlp::ArgumentParser.new.parse([
        "--username", "user",
        "--password", "pass",
        "-o", File.join(directory, "%(id)s.%(ext)s"),
        "https://auth.test/video.mp4",
      ])
      CrDlp::Client.new(parsed, request_director: director).download(parsed.urls).should eq(0)
      handler.authorizations.last.should eq("Basic dXNlcjpwYXNz")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "loads basic auth credentials from netrc files and commands" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      netrc = File.join(directory, "netrc")
      File.write(netrc, "machine auth.test login netuser password netpass\n")
      handler = AuthHeaderHandler.new
      director = CrDlp::Networking::RequestDirector.new([handler] of CrDlp::Networking::RequestHandler)
      parsed = CrDlp::ArgumentParser.new.parse([
        "--netrc-location", netrc,
        "-o", File.join(directory, "file-%(id)s.%(ext)s"),
        "https://auth.test/video.mp4",
      ])
      CrDlp::Client.new(parsed, request_director: director).download(parsed.urls).should eq(0)
      handler.authorizations.last.should eq("Basic bmV0dXNlcjpuZXRwYXNz")

      handler = AuthHeaderHandler.new
      director = CrDlp::Networking::RequestDirector.new([handler] of CrDlp::Networking::RequestHandler)
      parsed = CrDlp::ArgumentParser.new.parse([
        "--netrc-cmd", "ignored",
        "-o", File.join(directory, "cmd-%(id)s.%(ext)s"),
        "https://auth.test/video.mp4",
      ])
      CrDlp::Client.new(
        parsed,
        request_director: director,
        process_runner: NetrcCommandRunner.new("default login cmduser password cmdpass\n"),
      ).download(parsed.urls).should eq(0)
      handler.authorizations.last.should eq("Basic Y21kdXNlcjpjbWRwYXNz")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "maps the frozen no-check-certificates destination to TLS verification" do
    options = CrDlp::ParsedOptions.new({"no_check_certificate" => JSON::Any.new(true)})
    handler = CrDlp::Client.new(options).request_director.handlers.find(&.is_a?(CrDlp::Networking::CrystalHttpHandler))
      .not_nil!
      .as(CrDlp::Networking::CrystalHttpHandler)
    handler.verify_tls.should be_false
  end
end
