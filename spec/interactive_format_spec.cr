require "./spec_helper"

private class InteractiveFormatExtractor < CrDlp::Extractor
  def key : String
    "InteractiveFormat"
  end

  def name : String
    "interactive-format"
  end

  def suitable?(url : String) : Bool
    url == "interactive:formats"
  end

  def extract(url : String) : CrDlp::Info
    info = base_info("interactive", "interactive", url)
    info["url"] = "fixture://high"
    info["protocol"] = "fixture"
    info["ext"] = "mp4"
    info["formats"] = JSON::Any.new([
      interactive_format("low", 360),
      interactive_format("high", 1080),
    ])
    info
  end

  private def interactive_format(id : String, height : Int32) : JSON::Any
    JSON::Any.new({
      "format_id"    => JSON::Any.new(id),
      "url"          => JSON::Any.new("fixture://#{id}"),
      "protocol"     => JSON::Any.new("fixture"),
      "ext"          => JSON::Any.new("mp4"),
      "vcodec"       => JSON::Any.new("h264"),
      "acodec"       => JSON::Any.new("aac"),
      "height"       => JSON::Any.new(height.to_i64),
      "fixture_data" => JSON::Any.new(id),
    })
  end
end

private def interactive_client(input : IO, error : IO) : CrDlp::Client
  options = CrDlp::ParsedOptions.new({
    "format" => JSON::Any.new("-"),
  })
  client = CrDlp::Client.new(options, input: input, error: error)
  client.extractor_registry.prepend("InteractiveFormat", "interactive-format") do |instance|
    InteractiveFormatExtractor.new(instance)
  end
  client
end

describe "interactive format selection" do
  it "lists formats and retries syntax errors and unavailable selectors" do
    input = IO::Memory.new("(\nmissing\nlow\n")
    error = IO::Memory.new

    info = interactive_client(input, error)
      .extract_info("interactive:formats", download: false)

    info.string?("format_id").should eq("low")
    screen = error.to_s
    screen.should contain("Available formats for interactive")
    screen.should contain("Invalid format specification")
    screen.should contain("Requested format is not available")
    screen.scan("Enter format selector").size.should eq(3)
  end

  it "uses the default selector for an empty response" do
    info = interactive_client(
      IO::Memory.new("\n"),
      IO::Memory.new,
    ).extract_info("interactive:formats", download: false)

    info.string?("format_id").should eq("high")
  end

  it "bypasses the prompt for a single direct format" do
    options = CrDlp::ParsedOptions.new({
      "format" => JSON::Any.new("-"),
    })
    info = CrDlp::Client.new(
      options,
      input: IO::Memory.new,
      error: IO::Memory.new,
    ).extract_info("cr-dlp:fixture:direct", download: false)

    info.string?("format_id").should be_nil
    info.url.should eq("fixture://direct")
  end

  it "fails clearly when interactive input closes" do
    expect_raises(CrDlp::UsageError, /input closed/) do
      interactive_client(
        IO::Memory.new,
        IO::Memory.new,
      ).extract_info("interactive:formats", download: false)
    end
  end
end
