require "./spec_helper"

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
end
