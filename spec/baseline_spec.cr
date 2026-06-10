require "./spec_helper"

describe "the frozen yt-dlp baseline" do
  it "matches the pinned source and registry invariants" do
    manifest = JSON.parse({{ read_file("#{__DIR__}/../baseline/crystal/manifest.json") }}).as_h
    extractors = JSON.parse({{ read_file("#{__DIR__}/../baseline/crystal/extractors.json") }}).as_a

    manifest["source_commit"].as_s.should start_with(CrDlp::BASELINE_COMMIT)
    manifest["option_count"].as_i.should be > 300
    manifest["extractor_count"].as_i.should eq(extractors.size)
    manifest["extractor_test_cases"].as_i.should be > 1_000
    extractors.first.as_h["key"].as_s.should start_with("Youtube")
    extractors.last.as_h["key"].as_s.should eq("Generic")
  end

  it "keeps generated manifests deterministic" do
    options = JSON.parse({{ read_file("#{__DIR__}/../baseline/crystal/options.json") }}).as_a
    flags = options.flat_map { |entry| entry.as_h["flags"].as_a.map(&.as_s) }

    flags.should contain("--help")
    flags.should contain("--dump-single-json")
    flags.should contain("--plugin-dirs")
  end
end
