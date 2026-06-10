require "./spec_helper"

private def selector_info : CrDlp::Info
  info = CrDlp::Info.new
  info["id"] = "formats"
  info["title"] = "formats"
  info["url"] = "https://example.test/default"
  info["formats"] = JSON::Any.new([
    JSON::Any.new({
      "format_id" => JSON::Any.new("audio"),
      "url"       => JSON::Any.new("https://example.test/audio"),
      "ext"       => JSON::Any.new("m4a"),
      "vcodec"    => JSON::Any.new("none"),
      "acodec"    => JSON::Any.new("aac"),
      "tbr"       => JSON::Any.new(128.0),
    }),
    JSON::Any.new({
      "format_id" => JSON::Any.new("low"),
      "url"       => JSON::Any.new("https://example.test/low"),
      "ext"       => JSON::Any.new("mp4"),
      "vcodec"    => JSON::Any.new("h264"),
      "acodec"    => JSON::Any.new("none"),
      "height"    => JSON::Any.new(360_i64),
      "tbr"       => JSON::Any.new(500.0),
    }),
    JSON::Any.new({
      "format_id" => JSON::Any.new("high"),
      "url"       => JSON::Any.new("https://example.test/high"),
      "ext"       => JSON::Any.new("mp4"),
      "vcodec"    => JSON::Any.new("h264"),
      "acodec"    => JSON::Any.new("none"),
      "height"    => JSON::Any.new(1080_i64),
      "tbr"       => JSON::Any.new(2_000.0),
    }),
    JSON::Any.new({
      "format_id" => JSON::Any.new("muxed"),
      "url"       => JSON::Any.new("https://example.test/muxed"),
      "ext"       => JSON::Any.new("mp4"),
      "vcodec"    => JSON::Any.new("h264"),
      "acodec"    => JSON::Any.new("aac"),
      "height"    => JSON::Any.new(720_i64),
      "tbr"       => JSON::Any.new(1_500.0),
    }),
  ])
  info
end

private def filtering_info : CrDlp::Info
  info = CrDlp::Info.new
  info["id"] = "filters"
  info["title"] = "filters"
  info["url"] = "https://example.test/default"
  formats = [
    {"format_id" => "A", "filesize" => 500_i64, "width" => 1000_i64, "aspect_ratio" => 1.0, "quality" => 1_i64},
    {"format_id" => "B", "filesize" => 1000_i64, "width" => 500_i64, "aspect_ratio" => 1.33, "quality" => 2_i64},
    {"format_id" => "C", "filesize" => 1000_i64, "width" => 400_i64, "aspect_ratio" => 1.5, "quality" => 3_i64},
    {"format_id" => "D", "filesize" => 2000_i64, "width" => 600_i64, "aspect_ratio" => 1.78, "quality" => 4_i64},
    {"format_id" => "E", "filesize" => 3000_i64, "aspect_ratio" => 0.56, "quality" => 5_i64},
    {"format_id" => "F", "filesize" => nil, "quality" => 6_i64},
    {"format_id" => "G", "filesize" => 1_000_000_i64, "quality" => 7_i64},
  ]
  info["formats"] = JSON::Any.new(formats.map do |values|
    JSON::Any.new(values.transform_values { |value| JSON::Any.new(value) }.merge({
      "url"    => JSON::Any.new("https://example.test/#{values["format_id"]}"),
      "ext"    => JSON::Any.new("unknown"),
      "vcodec" => JSON::Any.new("unknown"),
      "acodec" => JSON::Any.new("unknown"),
    }))
  end)
  info
end

describe CrDlp::FormatSelector do
  it "selects quality aliases and exact IDs" do
    {
      "best"       => "muxed",
      "worst"      => "muxed",
      "bestvideo"  => "high",
      "worstvideo" => "low",
      "bestaudio"  => "audio",
      "low"        => "low",
    }.each do |selector, expected|
      info = selector_info
      CrDlp::FormatSelector.select!(info, selector)
      info.string?("format_id").should eq(expected)
    end
  end

  it "supports slash fallbacks and reports unavailable formats" do
    info = selector_info
    CrDlp::FormatSelector.select!(info, "missing/low")
    info.string?("format_id").should eq("low")

    expect_raises(CrDlp::ExtractorError, "Requested format is not available") do
      CrDlp::FormatSelector.select!(selector_info, "missing")
    end
  end

  it "builds multi-format plans with fallback and container selection" do
    info = selector_info
    CrDlp::FormatSelector.select!(info, "missing+bestaudio/bestvideo+bestaudio")

    info.string?("format_id").should eq("high+audio")
    info.string?("ext").should eq("mp4")
    info.array?("requested_formats").not_nil!.map do |format|
      format.as_h["format_id"].as_s
    end.should eq(["high", "audio"])

    preferred = selector_info
    CrDlp::FormatSelector.select!(preferred, "bestvideo+bestaudio", "mp4/mkv")
    preferred.string?("ext").should eq("mp4")
  end

  it "supports numeric filters, missing-value inclusion, and filesize units" do
    {
      "best[filesize<3000]"            => "D",
      "best[filesize<=3000]"           => "E",
      "best[filesize <= ? 3000]"       => "F",
      "best[filesize=1000][width>450]" => "B",
      "[filesize>?1]"                  => "G",
      "[filesize<1M]"                  => "E",
      "[filesize<1MiB]"                => "G",
      "best[aspect_ratio=1.5]"         => "C",
    }.each do |selector, expected|
      selected = CrDlp::FormatSelector.select_all(filtering_info, selector)
      selected.first.string?("format_id").should eq(expected)
    end

    selected = CrDlp::FormatSelector.select_all(filtering_info, "all[width>=400][width<=600]")
    selected.map(&.string?("format_id")).should eq(["D", "C", "B"])
  end

  it "supports string filters and negated string operators" do
    {
      "[format_id=abc-cba]"    => "abc-cba",
      "[format_id!=abc-cba]"   => "zxc-cxz",
      "[format_id^=abc]"       => "abc-cba",
      "[format_id!^=abc]"      => "zxc-cxz",
      "[format_id$=cba]"       => "abc-cba",
      "[format_id!$=cba]"      => "zxc-cxz",
      "[format_id*=bc-cb]"     => "abc-cba",
      "[format_id!*=bc-cb]"    => "zxc-cxz",
      "[format_id~=\"^abc-\"]" => "abc-cba",
    }.each do |selector, expected|
      info = selector_info
      formats = info.formats.select do |format|
        format.as_h["format_id"].as_s.in?("low", "high")
      end
      formats[0].as_h["format_id"] = JSON::Any.new("abc-cba")
      formats[1].as_h["format_id"] = JSON::Any.new("zxc-cxz")
      info["formats"] = JSON::Any.new(formats)
      CrDlp::FormatSelector.select_all(info, selector).first.string?("format_id").should eq(expected)
    end
  end

  it "supports grouping, comma lists, nth aliases, extensions, and star aliases" do
    selected = CrDlp::FormatSelector.select_all(
      selector_info,
      "(missing/low)+bestaudio,bestvideo.2,mp4,best*",
    )
    selected.map(&.string?("format_id")).should eq([
      "low+audio",
      "low",
      "muxed",
      "high",
    ])
  end

  it "does not let a filter create an incomplete-format fallback" do
    info = CrDlp::Info.new
    info["id"] = "fallback"
    info["title"] = "fallback"
    info["url"] = "https://example.test/default"
    info["formats"] = JSON::Any.new([
      JSON::Any.new({
        "format_id" => JSON::Any.new("regular"),
        "url"       => JSON::Any.new("https://example.test/regular"),
        "height"    => JSON::Any.new(360_i64),
        "vcodec"    => JSON::Any.new("h264"),
        "acodec"    => JSON::Any.new("aac"),
      }),
      JSON::Any.new({
        "format_id" => JSON::Any.new("video"),
        "url"       => JSON::Any.new("https://example.test/video"),
        "height"    => JSON::Any.new(720_i64),
        "vcodec"    => JSON::Any.new("h264"),
        "acodec"    => JSON::Any.new("none"),
      }),
    ])

    expect_raises(CrDlp::ExtractorError, "Requested format is not available") do
      CrDlp::FormatSelector.select_all(info, "best[height>360]")
    end
  end

  it "rejects malformed selector expressions and filters" do
    ["bestvideo,,best", "+bestaudio", "bestvideo+", "/", "[720<height]"].each do |selector|
      expect_raises(CrDlp::UsageError) do
        CrDlp::FormatSelector.select_all(selector_info, selector)
      end
    end
  end
end
