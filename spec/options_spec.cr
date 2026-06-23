require "./spec_helper"

describe CrDlp::ArgumentParser do
  it "parses subtitle selection and conversion options into structured values" do
    parsed = CrDlp::ArgumentParser.new.parse([
      "--write-subs",
      "--write-auto-subs",
      "--sub-langs", "en.*,ja",
      "--sub-format", "srt/vtt/best",
      "--convert-subs", "srt",
      "https://example.test/video.mp4",
    ])

    parsed.bool?("writesubtitles").should be_true
    parsed.bool?("writeautomaticsub").should be_true
    parsed.array?("subtitleslangs").not_nil!.map(&.as_s).should eq(["en.*", "ja"])
    parsed.string?("subtitlesformat").should eq("srt/vtt/best")
    parsed.string?("convertsubtitles").should eq("srt")
  end

  it "preserves write-all-thumbnails when followed by write-thumbnail" do
    parsed = CrDlp::ArgumentParser.new.parse([
      "--write-all-thumbnails",
      "--write-thumbnail",
      "--convert-thumbnails", "webp>jpg/png",
      "https://example.test/video.mp4",
    ])

    parsed.string?("writethumbnail").should eq("all")
    parsed.string?("convertthumbnails").should eq("webp>jpg/png")
  end

  it "parses selected, all, and disabled format availability checks" do
    CrDlp::ArgumentParser.new.parse([
      "--check-formats",
      "https://example.test/video.mp4",
    ]).string?("check_formats").should eq("selected")

    CrDlp::ArgumentParser.new.parse([
      "--check-all-formats",
      "https://example.test/video.mp4",
    ]).bool?("check_formats").should be_true

    CrDlp::ArgumentParser.new.parse([
      "--no-check-formats",
      "https://example.test/video.mp4",
    ]).bool?("check_formats").should be_false
  end

  it "loads the complete frozen option registry" do
    CrDlp::OptionSchema.new.option_count.should be > 290
  end

  it "parses long, short, combined, and callback options" do
    parsed = CrDlp::ArgumentParser.new.parse([
      "-qv",
      "-o", "%(id)s.%(ext)s",
      "--socket-timeout=5",
      "--format-sort", "res,codec",
      "https://example.test/video.mp4",
    ])

    parsed.bool?("quiet").should be_true
    parsed.bool?("verbose").should be_true
    parsed["socket_timeout"].not_nil!.as_f.should eq(5.0)
    parsed.urls.should eq(["https://example.test/video.mp4"])
    parsed["outtmpl"].not_nil!.as_h["default"].as_s.should eq("%(id)s.%(ext)s")
  end

  it "does not interpret a Windows drive as a callback dictionary key" do
    parsed = CrDlp::ArgumentParser.new.parse([
      "-o", "C:\\Temp\\%(id)s.%(ext)s",
      "cr-dlp:fixture:path",
    ])

    parsed["outtmpl"].not_nil!.as_h["default"].as_s.should eq("C:\\Temp\\%(id)s.%(ext)s")
  end

  it "prepends repeated format-sort arguments and supports reset" do
    parsed = CrDlp::ArgumentParser.new.parse([
      "-S", "proto",
      "-S", "res,codec",
      "https://example.test/video.mp4",
    ])
    parsed.array?("format_sort").not_nil!.map(&.as_s).should eq(%w[res codec proto])

    reset = CrDlp::ArgumentParser.new.parse([
      "-S", "proto",
      "--format-sort-reset",
      "https://example.test/video.mp4",
    ])
    reset.array?("format_sort").not_nil!.should be_empty
  end

  it "preserves repeated print templates by stage" do
    parsed = CrDlp::ArgumentParser.new.parse([
      "-O", "title",
      "-O", "video:%(height)04d",
      "https://example.test/video.mp4",
    ])

    parsed.hash?("forceprint").not_nil!["video"].as_a.map(&.as_s)
      .should eq(["title", "%(height)04d"])
  end

  it "parses print-to-file as staged template/path pairs" do
    parsed = CrDlp::ArgumentParser.new.parse([
      "--print-to-file", "title", "titles.txt",
      "--print-to-file", "playlist:%(playlist_id)s", "playlists.txt",
      "https://example.test/video.mp4",
    ])

    output = parsed.hash?("print_to_file").not_nil!
    video = output["video"].as_a.first.as_h
    video["template"].as_s.should eq("title")
    video["path"].as_s.should eq("titles.txt")
    playlist = output["playlist"].as_a.first.as_h
    playlist["template"].as_s.should eq("%(playlist_id)s")
    playlist["path"].as_s.should eq("playlists.txt")
  end

  it "preserves repeated exec commands by stage and parses media conversion options" do
    parsed = CrDlp::ArgumentParser.new.parse([
      "--exec", "echo one",
      "--exec", "before_dl:echo two",
      "--exec", "echo three",
      "--extract-audio",
      "--audio-format", "mp3",
      "--audio-quality", "128K",
      "--remux-video", "mov>mp4/mkv",
      "https://example.test/video.mp4",
    ])

    commands = parsed.hash?("exec_cmd").not_nil!
    commands["after_move"].as_a.map(&.as_s).should eq(["echo one", "echo three"])
    commands["before_dl"].as_a.map(&.as_s).should eq(["echo two"])
    parsed.bool?("extractaudio").should be_true
    parsed.string?("audioformat").should eq("mp3")
    parsed.string?("audioquality").should eq("128K")
    parsed.string?("remuxvideo").should eq("mov>mp4/mkv")
  end

  it "parses staged metadata interpretation and three-value replacements" do
    parsed = CrDlp::ArgumentParser.new.parse([
      "--parse-metadata", "title:%(artist)s - %(title)s",
      "--parse-metadata", "after_filter:webpage_url:%(id)s",
      "--replace-in-metadata", "video:title,artist", "foo", "bar",
      "https://example.test/video.mp4",
    ])

    actions = parsed.hash?("parse_metadata").not_nil!
    pre_process = actions["pre_process"].as_a.map(&.as_h)
    pre_process.size.should eq(1)
    pre_process[0]["input"].as_s.should eq("title")
    pre_process[0]["output"].as_s.should eq("%(artist)s - %(title)s")

    after_filter = actions["after_filter"].as_a.first.as_h
    after_filter["input"].as_s.should eq("webpage_url")
    after_filter["output"].as_s.should eq("%(id)s")

    replacements = actions["video"].as_a.map(&.as_h)
    replacements.map { |action| action["field"].as_s }.should eq(["title", "artist"])
    replacements.each do |action|
      action["search"].as_s.should eq("foo")
      action["replacement"].as_s.should eq("bar")
    end
    parsed.urls.should eq(["https://example.test/video.mp4"])
  end

  it "keeps non-stage colons inside exec and metadata values" do
    parsed = CrDlp::ArgumentParser.new.parse([
      "--exec", "echo https://example.test/video",
      "--parse-metadata", "%(webpage_url)s:%(scheme)s://%(host)s/%(path)s",
      "https://example.test/video.mp4",
    ])

    parsed.hash?("exec_cmd").not_nil!["after_move"].as_a.first.as_s
      .should eq("echo https://example.test/video")
    action = parsed.hash?("parse_metadata").not_nil!["pre_process"].as_a.first.as_h
    action["input"].as_s.should eq("%(webpage_url)s")
    action["output"].as_s.should eq("%(scheme)s://%(host)s/%(path)s")
  end

  it "validates chapter removal expressions before extraction" do
    parsed = CrDlp::ArgumentParser.new.parse([
      "--remove-chapters", "^Sponsor",
      "--remove-chapters", "*1:30-2:45,3:00-inf",
      "https://example.test/video.mp4",
    ])
    parsed.array?("remove_chapters").not_nil!.map(&.as_s)
      .should eq(["^Sponsor", "*1:30-2:45,3:00-inf"])

    expect_raises(CrDlp::UsageError, "invalid --remove-chapters regex") do
      CrDlp::ArgumentParser.new.parse([
        "--remove-chapters", "[",
        "https://example.test/video.mp4",
      ])
    end
    expect_raises(CrDlp::UsageError, "expected *START-END") do
      CrDlp::ArgumentParser.new.parse([
        "--remove-chapters", "*not-a-range",
        "https://example.test/video.mp4",
      ])
    end
  end

  it "expands SponsorBlock aliases, exclusions, and defaults" do
    parsed = CrDlp::ArgumentParser.new.parse([
      "--sponsorblock-mark", "default,-preview",
      "--sponsorblock-remove", "default,-intro",
      "https://example.test/video.mp4",
    ])

    marked = parsed.array?("sponsorblock_mark").not_nil!.map(&.as_s)
    marked.should contain("sponsor")
    marked.should contain("chapter")
    marked.should_not contain("preview")

    removed = parsed.array?("sponsorblock_remove").not_nil!.map(&.as_s)
    removed.should contain("sponsor")
    removed.should_not contain("filler")
    removed.should_not contain("intro")
    removed.should_not contain("chapter")

    expect_raises(CrDlp::UsageError, "invalid SponsorBlock category") do
      CrDlp::ArgumentParser.new.parse([
        "--sponsorblock-remove", "chapter",
        "https://example.test/video.mp4",
      ])
    end
  end
end
