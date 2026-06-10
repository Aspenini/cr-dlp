require "./spec_helper"

private def sortable_info(formats : Array(Hash(String, JSON::Any))) : CrDlp::Info
  info = CrDlp::Info.new
  info["id"] = "sort"
  info["title"] = "sort"
  info["url"] = "https://example.test/default"
  info["formats"] = JSON::Any.new(formats.map { |format| JSON::Any.new(format) })
  info
end

private def sortable_format(
  id : String,
  ext : String,
  **fields,
) : Hash(String, JSON::Any)
  format = {
    "format_id" => JSON::Any.new(id),
    "ext"       => JSON::Any.new(ext),
    "url"       => JSON::Any.new("https://example.test/#{id}.#{ext}"),
  }
  fields.each do |key, value|
    format[key.to_s] = JSON::Any.new(value)
  end
  format
end

private def best_sorted(
  info : CrDlp::Info,
  fields = [] of String,
  force = false,
  prefer_free = false,
  selector = "best*",
) : String
  CrDlp::FormatSelector.select_all(
    info,
    selector,
    format_sort: fields,
    format_sort_force: force,
    prefer_free_formats: prefer_free,
  ).first.string?("format_id").not_nil!
end

describe CrDlp::FormatSorter do
  it "uses yt-dlp container preferences and prefer-free ordering" do
    formats = [
      sortable_format("webm", "webm", height: 720_i64),
      sortable_format("mp4", "mp4", height: 720_i64),
      sortable_format("flv", "flv", height: 720_i64),
    ]
    best_sorted(sortable_info(formats)).should eq("mp4")
    best_sorted(sortable_info(formats), prefer_free: true).should eq("webm")

    higher = [
      sortable_format("webm", "webm", height: 720_i64),
      sortable_format("mp4", "mp4", height: 1080_i64),
    ]
    best_sorted(sortable_info(higher), prefer_free: true).should eq("mp4")
  end

  it "sorts audio formats by user bitrate and extension fields" do
    formats = [
      sortable_format("mp3-64", "mp3", abr: 64_i64, vcodec: "none"),
      sortable_format("ogg-64", "ogg", abr: 64_i64, vcodec: "none"),
      sortable_format("aac-64", "aac", abr: 64_i64, vcodec: "none"),
      sortable_format("mp3-32", "mp3", abr: 32_i64, vcodec: "none"),
    ]
    best_sorted(sortable_info(formats), %w[abr ext]).should eq("aac-64")
    best_sorted(sortable_info(formats), %w[abr ext], prefer_free: true).should eq("ogg-64")
  end

  it "supports reverse, capped, and closest numeric ordering" do
    formats = [
      sortable_format("360", "mp4", height: 360_i64, filesize: 10_000_000_i64),
      sortable_format("720", "mp4", height: 720_i64, filesize: 48_000_000_i64),
      sortable_format("1080", "mp4", height: 1080_i64, filesize: 80_000_000_i64),
    ]
    best_sorted(sortable_info(formats), ["+res"]).should eq("360")
    best_sorted(sortable_info(formats), ["res:720"]).should eq("720")
    best_sorted(sortable_info(formats), ["filesize~50M"]).should eq("720")
  end

  it "supports ordered codec targets in both directions" do
    formats = [
      sortable_format("av1", "mp4", vcodec: "av1", acodec: "none"),
      sortable_format("vp9-hdr", "mp4", vcodec: "vp09.02.50.10", acodec: "none"),
      sortable_format("vp9-sdr", "mp4", vcodec: "vp09.00.50.08", acodec: "none"),
      sortable_format("h265", "mp4", vcodec: "h265", acodec: "none"),
    ]
    best_sorted(sortable_info(formats), ["vcodec:vp9.2"], selector: "bestvideo").should eq("vp9-hdr")
    best_sorted(sortable_info(formats), ["vcodec:vp9"], selector: "bestvideo").should eq("vp9-sdr")
    best_sorted(sortable_info(formats), ["+vcodec:vp9.2"], selector: "bestvideo").should eq("vp9-hdr")
    best_sorted(sortable_info(formats), ["+vcodec:vp9"], selector: "bestvideo").should eq("vp9-sdr")
  end

  it "applies a single combined-field limit only to its first field" do
    formats = [
      sortable_format("h264-flac", "mp4", vcodec: "h264", acodec: "flac"),
      sortable_format("h264-aac", "mp4", vcodec: "h264", acodec: "aac"),
    ]

    best_sorted(sortable_info(formats), ["codec:h264"]).should eq("h264-flac")
  end

  it "keeps stream presence above user fields unless force is enabled" do
    formats = [
      sortable_format("video", "mp4", vcodec: "h264", acodec: "none"),
      sortable_format("audio", "m4a", vcodec: "none", acodec: "aac"),
    ]
    best_sorted(sortable_info(formats), ["+hasvid"]).should eq("video")
    best_sorted(sortable_info(formats), ["+hasvid"], force: true).should eq("audio")
  end

  it "honors extractor sort fields after user fields" do
    info = sortable_info([
      sortable_format("low", "mp4", height: 360_i64, source_preference: 10_i64),
      sortable_format("high", "mp4", height: 1080_i64, source_preference: 1_i64),
    ])
    info["_format_sort_fields"] = JSON::Any.new([JSON::Any.new("source")])

    best_sorted(info).should eq("low")
    best_sorted(info, ["res"]).should eq("high")
  end
end
