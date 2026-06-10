require "./spec_helper"

private SPONSOR_NAMES = {
  "sponsor"        => "Sponsor",
  "intro"          => "Intermission/Intro Animation",
  "outro"          => "Endcards/Credits",
  "selfpromo"      => "Unpaid/Self Promotion",
  "preview"        => "Preview/Recap",
  "filler"         => "Filler Tangent",
  "interaction"    => "Interaction Reminder",
  "music_offtopic" => "Non-Music Section",
}

private def chapter(start_time, end_time, title = nil, remove = false) : JSON::Any
  values = {
    "start_time" => JSON::Any.new(start_time.to_f64),
    "end_time"   => JSON::Any.new(end_time.to_f64),
  }
  values["title"] = JSON::Any.new(title) if title
  values["remove"] = JSON::Any.new(true) if remove
  JSON::Any.new(values)
end

private def sponsor_chapter(
  start_time,
  end_time,
  category,
  remove = false,
  title = nil,
) : JSON::Any
  name = title || SPONSOR_NAMES[category]
  values = chapter(start_time, end_time).as_h
  values["_categories"] = JSON::Any.new([
    JSON::Any.new([
      JSON::Any.new(category),
      JSON::Any.new(start_time.to_f64),
      JSON::Any.new(end_time.to_f64),
      JSON::Any.new(name),
    ]),
  ])
  values["remove"] = JSON::Any.new(true) if remove
  JSON::Any.new(values)
end

private def sequential_chapters(ends, titles) : Array(JSON::Any)
  start_time = 0.0
  ends.zip(titles).map do |end_time, title|
    value = chapter(start_time, end_time, title)
    start_time = end_time.to_f64
    value
  end
end

private def summarized_chapters(values : Array(JSON::Any))
  values.map do |value|
    chapter = value.as_h
    {
      chapter["start_time"].as_f,
      chapter["end_time"].as_f,
      chapter["title"]?.try(&.as_s?),
    }
  end
end

private class ChapterRunner < CrDlp::ProcessRunner
  getter calls = [] of Tuple(String, Array(String))

  def initialize(@succeeds = true)
  end

  def executable_available?(command : String) : Bool
    !command.includes?("ffprobe")
  end

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    @calls << {command, arguments.dup}
    return CrDlp::ProcessResult.new(1, "", "cut failed") unless @succeeds
    File.write(arguments.last, "CUT")
    CrDlp::ProcessResult.new(0, "", "")
  end
end

private def chapter_processor(
  options = CrDlp::ParsedOptions.new,
  runner = ChapterRunner.new,
)
  client = CrDlp::Client.new(options, process_runner: runner, auto_init: false)
  {CrDlp::ModifyChaptersPostProcessor.new(client), runner}
end

describe CrDlp::ModifyChaptersPostProcessor do
  it "preserves non-overlapping chapters" do
    processor, _ = chapter_processor
    chapters = sequential_chapters([10, 20, 30, 40], %w[c1 c2 c3 c4])

    arranged, cuts = processor.arrange_chapters(chapters)

    summarized_chapters(arranged).should eq(summarized_chapters(chapters))
    cuts.should be_empty
  end

  it "inserts adjacent SponsorBlock chapters" do
    processor, _ = chapter_processor
    chapters = [
      *sequential_chapters([70], ["c"]),
      sponsor_chapter(10, 20, "sponsor"),
      sponsor_chapter(20, 30, "selfpromo"),
      sponsor_chapter(30, 40, "interaction"),
    ]

    arranged, cuts = processor.arrange_chapters(chapters)

    summarized_chapters(arranged).should eq(summarized_chapters(
      sequential_chapters(
        [10, 20, 30, 40, 70],
        [
          "c",
          "[SponsorBlock]: Sponsor",
          "[SponsorBlock]: Unpaid/Self Promotion",
          "[SponsorBlock]: Interaction Reminder",
          "c",
        ],
      ),
    ))
    cuts.should be_empty
  end

  it "combines overlapping sponsor categories and restores normal chapters" do
    processor, _ = chapter_processor
    chapters = [
      *sequential_chapters([70], ["c"]),
      sponsor_chapter(10, 30, "sponsor"),
      sponsor_chapter(20, 50, "selfpromo"),
      sponsor_chapter(40, 60, "interaction"),
    ]

    arranged, _ = processor.arrange_chapters(chapters)

    summarized_chapters(arranged).should eq(summarized_chapters(
      sequential_chapters(
        [10, 20, 30, 40, 50, 60, 70],
        [
          "c",
          "[SponsorBlock]: Sponsor",
          "[SponsorBlock]: Sponsor, Unpaid/Self Promotion",
          "[SponsorBlock]: Unpaid/Self Promotion",
          "[SponsorBlock]: Unpaid/Self Promotion, Interaction Reminder",
          "[SponsorBlock]: Interaction Reminder",
          "c",
        ],
      ),
    ))
  end

  it "merges adjacent and overlapping cuts" do
    processor, _ = chapter_processor
    chapters = [
      *sequential_chapters([70], ["c"]),
      sponsor_chapter(10, 20, "sponsor"),
      sponsor_chapter(20, 30, "interaction", remove: true),
      chapter(30, 40, remove: true),
      sponsor_chapter(40, 50, "selfpromo", remove: true),
      sponsor_chapter(50, 60, "interaction"),
    ]

    arranged, cuts = processor.arrange_chapters(chapters)

    summarized_chapters(arranged).should eq(summarized_chapters(
      sequential_chapters(
        [10, 20, 30, 40],
        ["c", "[SponsorBlock]: Sponsor", "[SponsorBlock]: Interaction Reminder", "c"],
      ),
    ))
    cuts.size.should eq(1)
    cuts.first.as_h["start_time"].as_f.should eq(20)
    cuts.first.as_h["end_time"].as_f.should eq(50)
  end

  it "cuts across multiple normal chapters and adjusts the timeline" do
    processor, _ = chapter_processor
    cuts = [chapter(10, 90, remove: true)]
    chapters = sequential_chapters(
      [20, 40, 60, 80, 100],
      %w[c1 c2 c3 c4 c5],
    ) + cuts

    arranged, actual_cuts = processor.arrange_chapters(chapters)

    summarized_chapters(arranged).should eq(summarized_chapters(
      sequential_chapters([10, 20], %w[c1 c5]),
    ))
    actual_cuts.size.should eq(1)
    actual_cuts.first.as_h["start_time"].as_f.should eq(10)
    actual_cuts.first.as_h["end_time"].as_f.should eq(90)
  end

  it "hides sponsors covered by cuts and shifts later sponsors" do
    processor, _ = chapter_processor
    cuts = [sponsor_chapter(20, 50, "selfpromo", remove: true)]
    chapters = [
      *sequential_chapters([60], ["c"]),
      sponsor_chapter(10, 20, "intro"),
      sponsor_chapter(30, 40, "sponsor"),
      sponsor_chapter(50, 60, "outro"),
      *cuts,
    ]

    arranged, actual_cuts = processor.arrange_chapters(chapters)

    summarized_chapters(arranged).should eq(summarized_chapters(
      sequential_chapters(
        [10, 20, 30],
        ["c", "[SponsorBlock]: Intermission/Intro Animation", "[SponsorBlock]: Endcards/Credits"],
      ),
    ))
    actual_cuts.first.as_h["start_time"].as_f.should eq(20)
    actual_cuts.first.as_h["end_time"].as_f.should eq(50)
  end

  it "handles long runs of overlapping sponsors" do
    processor, _ = chapter_processor
    chapters = [
      *sequential_chapters([110], ["c"]),
      sponsor_chapter(0, 30, "intro"),
      sponsor_chapter(20, 50, "sponsor"),
      sponsor_chapter(40, 60, "selfpromo"),
      sponsor_chapter(70, 90, "sponsor"),
      sponsor_chapter(80, 100, "sponsor"),
      sponsor_chapter(90, 110, "sponsor"),
    ]

    arranged, cuts = processor.arrange_chapters(chapters)

    summarized_chapters(arranged).should eq(summarized_chapters(
      sequential_chapters(
        [20, 30, 40, 50, 60, 70, 110],
        [
          "[SponsorBlock]: Intermission/Intro Animation",
          "[SponsorBlock]: Intermission/Intro Animation, Sponsor",
          "[SponsorBlock]: Sponsor",
          "[SponsorBlock]: Sponsor, Unpaid/Self Promotion",
          "[SponsorBlock]: Unpaid/Self Promotion",
          "c",
          "[SponsorBlock]: Sponsor",
        ],
      ),
    ))
    cuts.should be_empty
  end

  it "handles runs of overlapping cuts" do
    processor, _ = chapter_processor
    chapters = [
      *sequential_chapters([170], ["c"]),
      chapter(0, 30, remove: true),
      sponsor_chapter(20, 50, "sponsor", remove: true),
      chapter(40, 60, remove: true),
      sponsor_chapter(70, 90, "sponsor", remove: true),
      chapter(80, 100, remove: true),
      chapter(90, 110, remove: true),
      sponsor_chapter(120, 140, "sponsor", remove: true),
      sponsor_chapter(130, 160, "selfpromo", remove: true),
      chapter(150, 170, remove: true),
    ]

    arranged, cuts = processor.arrange_chapters(chapters)

    summarized_chapters(arranged).should eq(summarized_chapters(
      sequential_chapters([20], ["c"]),
    ))
    cuts.map do |value|
      cut = value.as_h
      {cut["start_time"].as_f, cut["end_time"].as_f}
    end.should eq([{0.0, 60.0}, {70.0, 110.0}, {120.0, 170.0}])
  end

  it "handles cuts at video boundaries" do
    processor, _ = chapter_processor
    chapters = sequential_chapters([20, 40, 60], %w[c1 c2 c3]) + [
      chapter(0, 10, remove: true),
      chapter(50, 60, remove: true),
    ]

    arranged, cuts = processor.arrange_chapters(chapters)

    summarized_chapters(arranged).should eq(summarized_chapters(
      sequential_chapters([10, 30, 40], %w[c1 c2 c3]),
    ))
    cuts.size.should eq(2)
  end

  it "returns no chapters when the entire timeline is cut" do
    processor, _ = chapter_processor
    chapters = sequential_chapters([10, 20, 30, 40], %w[c1 c2 c3 c4]) + [
      chapter(0, 20, remove: true),
      chapter(20, 40, remove: true),
    ]

    arranged, cuts = processor.arrange_chapters(chapters)

    arranged.should be_empty
    cuts.size.should eq(1)
    cuts.first.as_h["start_time"].as_f.should eq(0)
    cuts.first.as_h["end_time"].as_f.should eq(40)
  end

  it "preserves original tiny chapters but removes tiny cut fragments" do
    processor, _ = chapter_processor
    original = sequential_chapters([0.1, 0.2, 0.3, 0.4], %w[c1 c2 c3 c4])
    arranged, _ = processor.arrange_chapters(original)
    summarized_chapters(arranged).should eq(summarized_chapters(original))

    cut_input = sequential_chapters([2, 3, 3.5], %w[c1 c2 c3]) + [
      chapter(1.5, 2.5, remove: true),
    ]
    arranged, _ = processor.arrange_chapters(cut_input)
    summarized_chapters(arranged).should eq(summarized_chapters(
      sequential_chapters([2, 2.5], %w[c1 c3]),
    ))
  end

  it "ignores tiny sponsors and chooses the shortest overlapping sponsor name" do
    processor, _ = chapter_processor
    tiny = [
      sponsor_chapter(0, 0.1, "intro"),
      chapter(0.1, 0.2, "c1"),
      sponsor_chapter(0.2, 0.3, "sponsor"),
      chapter(0.3, 0.4, "c2"),
      sponsor_chapter(0.4, 0.5, "outro"),
    ]
    arranged, _ = processor.arrange_chapters(tiny)
    summarized_chapters(arranged).should eq(summarized_chapters(
      sequential_chapters([0.3, 0.5], %w[c1 c2]),
    ))

    named_processor, _ = chapter_processor(CrDlp::ParsedOptions.new({
      "sponsorblock_chapter_title" => JSON::Any.new("[SponsorBlock]: %(name)s"),
    }))
    overlapping = [
      *sequential_chapters([10], ["c"]),
      sponsor_chapter(2, 8, "sponsor"),
      sponsor_chapter(4, 6, "selfpromo"),
    ]
    arranged, _ = named_processor.arrange_chapters(overlapping)
    summarized_chapters(arranged).should eq(summarized_chapters(
      sequential_chapters(
        [2, 4, 6, 8, 10],
        [
          "c",
          "[SponsorBlock]: Sponsor",
          "[SponsorBlock]: Unpaid/Self Promotion",
          "[SponsorBlock]: Sponsor",
          "c",
        ],
      ),
    ))
  end

  it "builds pinned concat directives without zero-duration chunks" do
    processor, _ = chapter_processor
    cuts = [chapter(1, 2), chapter(10, 20)]

    options = processor.make_concat_options(cuts, 30)
    processor.concat_spec("test", options).should eq(
      "ffconcat version 1.0\n" \
      "file 'file:test'\n" \
      "outpoint 1.000000\n" \
      "file 'file:test'\n" \
      "inpoint 2.000000\n" \
      "outpoint 10.000000\n" \
      "file 'file:test'\n" \
      "inpoint 20.000000\n",
    )

    start_options = processor.make_concat_options([chapter(0, 1), chapter(10, 20)], 30)
    start_options.first.should eq({"inpoint" => "1.000000", "outpoint" => "10.000000"})

    end_options = processor.make_concat_options(cuts, 20)
    end_options.size.should eq(2)
    end_options.last.should eq({"inpoint" => "2.000000", "outpoint" => "10.000000"})
  end

  it "quotes apostrophes for ffconcat" do
    processor, _ = chapter_processor
    processor.quote_for_ffmpeg("special ' ''characters'''galore")
      .should eq(%q('special '\'' '\'\''characters'\'\'\''galore'))
    processor.quote_for_ffmpeg("'''special ' characters ' galore")
      .should eq(%q(\'\'\''special '\'' characters '\'' galore'))
    processor.quote_for_ffmpeg("special ' characters ' galore'''")
      .should eq(%q('special '\'' characters '\'' galore'\'\'\'))
  end

  it "cuts media and supported subtitle sidecars transactionally" do
    directory = File.join(Dir.tempdir, "cr-dlp-chapters-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      media = File.join(directory, "media.mp4")
      subtitle = File.join(directory, "media.en.vtt")
      File.write(media, "MEDIA")
      File.write(subtitle, "WEBVTT")
      runner = ChapterRunner.new
      options = CrDlp::ParsedOptions.new({
        "remove_chapters" => JSON::Any.new([JSON::Any.new("^Skip$")]),
      })
      processor, _ = chapter_processor(options, runner)
      info = CrDlp::Info.new({
        "id"       => JSON::Any.new("chapters"),
        "title"    => JSON::Any.new("Chapters"),
        "ext"      => JSON::Any.new("mp4"),
        "filepath" => JSON::Any.new(media),
        "duration" => JSON::Any.new(4.0),
        "chapters" => JSON::Any.new(sequential_chapters(
          [1, 2, 4],
          ["Keep", "Skip", "End"],
        )),
        "requested_subtitles" => JSON::Any.new({
          "en" => JSON::Any.new({
            "filepath" => JSON::Any.new(subtitle),
            "ext"      => JSON::Any.new("vtt"),
          }),
        }),
      })

      processor.run(info)

      File.read(media).should eq("CUT")
      File.read(subtitle).should eq("CUT")
      summarized_chapters(info.array?("chapters").not_nil!).should eq(
        summarized_chapters(sequential_chapters([1, 3], ["Keep", "End"])),
      )
      info.float?("duration").should eq(3)
      runner.calls.size.should eq(2)
      Dir.glob(File.join(directory, "*.concat")).should be_empty
      Dir.glob(File.join(directory, "*.uncut.*")).should be_empty
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "leaves originals untouched when ffmpeg fails" do
    directory = File.join(Dir.tempdir, "cr-dlp-chapters-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      media = File.join(directory, "media.mp4")
      File.write(media, "MEDIA")
      options = CrDlp::ParsedOptions.new({
        "remove_chapters" => JSON::Any.new([JSON::Any.new("^Skip$")]),
      })
      processor, _ = chapter_processor(options, ChapterRunner.new(succeeds: false))
      info = CrDlp::Info.new({
        "id"       => JSON::Any.new("chapters"),
        "title"    => JSON::Any.new("Chapters"),
        "ext"      => JSON::Any.new("mp4"),
        "filepath" => JSON::Any.new(media),
        "duration" => JSON::Any.new(2.0),
        "chapters" => JSON::Any.new(sequential_chapters(
          [1, 2],
          ["Keep", "Skip"],
        )),
      })

      expect_raises(CrDlp::PostProcessingError, "cut failed") do
        processor.run(info)
      end
      File.read(media).should eq("MEDIA")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "removes a chapter from real media with ffmpeg" do
    ffmpeg = Process.find_executable("ffmpeg")
    ffprobe = Process.find_executable("ffprobe")
    pending!("ffmpeg and ffprobe are required") unless ffmpeg && ffprobe

    directory = File.join(Dir.tempdir, "cr-dlp-real-chapters-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      media = File.join(directory, "media.mp4")
      generation = Process.run(
        ffmpeg,
        [
          "-y", "-loglevel", "error",
          "-f", "lavfi", "-i", "testsrc=size=64x64:rate=10:duration=4",
          "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
          "-c:v", "mpeg4", "-g", "10", "-c:a", "aac", "-shortest", media,
        ],
      )
      generation.success?.should be_true

      options = CrDlp::ParsedOptions.new({
        "remove_chapters" => JSON::Any.new([JSON::Any.new("^Skip$")]),
      })
      client = CrDlp::Client.new(options, auto_init: false)
      info = CrDlp::Info.new({
        "id"       => JSON::Any.new("chapters"),
        "title"    => JSON::Any.new("Chapters"),
        "ext"      => JSON::Any.new("mp4"),
        "filepath" => JSON::Any.new(media),
        "duration" => JSON::Any.new(4.0),
        "chapters" => JSON::Any.new(sequential_chapters(
          [1, 2, 4],
          ["Keep", "Skip", "End"],
        )),
      })

      CrDlp::ModifyChaptersPostProcessor.new(client).run(info)

      probe_output = IO::Memory.new
      probe = Process.run(
        ffprobe,
        [
          "-v", "error",
          "-show_entries", "format=duration",
          "-of", "default=nw=1:nk=1",
          media,
        ],
        output: probe_output,
      )
      probe.success?.should be_true
      duration = probe_output.to_s.strip.to_f
      duration.should be_close(3.0, 0.35)
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
