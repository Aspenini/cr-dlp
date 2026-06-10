require "./spec_helper"

private class MetadataStageRunner < CrDlp::ProcessRunner
  getter shell_calls = [] of String

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    source = arguments.index("-i").try { |index| arguments[index + 1]? }
    contents = source && File.exists?(source) ? File.read(source) : ""
    File.write(arguments.last, contents)
    CrDlp::ProcessResult.new(0, "", "")
  end

  def run_shell(command : String) : CrDlp::ProcessResult
    @shell_calls << command
    CrDlp::ProcessResult.new(0, "", "")
  end
end

private def metadata_action(type : String, values : Hash(String, String)) : JSON::Any
  action = {"type" => JSON::Any.new(type)}
  values.each { |key, value| action[key] = JSON::Any.new(value) }
  JSON::Any.new(action)
end

describe CrDlp::MetadataParserPostProcessor do
  it "converts fields and templates into regular expressions" do
    CrDlp::MetadataParserPostProcessor.format_to_regex("%(title)s - %(artist)s")
      .should eq("(?<title>.+)\\ \\-\\ (?<artist>.+)")
    CrDlp::MetadataParserPostProcessor.format_to_regex("(?<x>.+)")
      .should eq("(?<x>.+)")
    CrDlp::MetadataParserPostProcessor.format_to_regex("x")
      .should eq("(?<x>.+)")
    CrDlp::MetadataParserPostProcessor.field_to_template("title")
      .should eq("%(title)s")
    CrDlp::MetadataParserPostProcessor.field_to_template("foo bar")
      .should eq("foo bar")
  end

  it "interprets fields and applies ordered replacements" do
    actions = [
      metadata_action("interpret", {
        "input"  => "title",
        "output" => "%(artist)s - %(track)s",
      }),
      metadata_action("replace", {
        "field"       => "artist",
        "search"      => "\\s+",
        "replacement" => "_",
      }),
    ]
    info = CrDlp::Info.new({
      "id"    => JSON::Any.new("metadata"),
      "title" => JSON::Any.new("Crystal Band - First Song"),
    })

    client = CrDlp::Client.new(auto_init: false)
    CrDlp::MetadataParserPostProcessor.new(client, actions).run(info)

    info.string?("artist").should eq("Crystal_Band")
    info.string?("track").should eq("First Song")
  end

  it "runs metadata actions before exec at each pipeline stage" do
    directory = File.join(Dir.tempdir, "cr-dlp-metadata-stage-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      options = CrDlp::ParsedOptions.new({
        "outtmpl" => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
        }),
        "parse_metadata" => JSON::Any.new({
          "video" => JSON::Any.new([
            metadata_action("replace", {
              "field"       => "title",
              "search"      => "Before",
              "replacement" => "After",
            }),
          ]),
        }),
        "exec_cmd" => JSON::Any.new({
          "video" => JSON::Any.new([JSON::Any.new("echo %(title)q")]),
        }),
        "fixup" => JSON::Any.new("never"),
      })
      runner = MetadataStageRunner.new
      info = CrDlp::Info.new({
        "id"           => JSON::Any.new("stage"),
        "title"        => JSON::Any.new("Before"),
        "url"          => JSON::Any.new("fixture://stage"),
        "protocol"     => JSON::Any.new("fixture"),
        "ext"          => JSON::Any.new("txt"),
        "fixture_data" => JSON::Any.new("stage"),
      })

      CrDlp::Client.new(options, process_runner: runner).process_info(info)

      info.string?("title").should eq("After")
      runner.shell_calls.first.should contain("After")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
