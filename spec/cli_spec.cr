require "./spec_helper"

describe CrDlp::CLI do
  it "accepts a configuration file in the executable path" do
    path = File.tempname("cr-dlp-config", ".conf")
    begin
      File.write(path, "--simulate\n--dump-single-json\n")
      CrDlp::CLI.run(["--config-location", path, "cr-dlp:fixture:cli"]).should eq(0)
    ensure
      File.delete?(path)
    end
  end

  it "loads yt-dlp.conf from --config-locations directories" do
    directory = File.join(Dir.tempdir, "cr-dlp-config-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      output = File.join(directory, "ids.txt")
      config_output = output.gsub("\\", "/")
      File.write(File.join(directory, "yt-dlp.conf"), "--print-to-file id \"#{config_output}\"\n")

      CrDlp::CLI.run(["--config-locations", directory, "cr-dlp:fixture:dircfg"]).should eq(0)
      File.read(output).should eq("dircfg\n")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "expands nested config locations and honors --no-config-locations" do
    directory = File.join(Dir.tempdir, "cr-dlp-config-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      first = File.join(directory, "first.conf")
      nested = File.join(directory, "nested.conf")
      kept = File.join(directory, "kept.txt")
      cleared = File.join(directory, "cleared.txt")
      nested_config = nested.gsub("\\", "/")
      kept_config = kept.gsub("\\", "/")
      cleared_config = cleared.gsub("\\", "/")
      File.write(nested, "--print-to-file id \"#{cleared_config}\"\n")
      File.write(first, "--config-locations \"#{nested_config}\"\n--no-config-locations\n--print-to-file id \"#{kept_config}\"\n")

      CrDlp::CLI.run(["--config-locations", first, "cr-dlp:fixture:nested"]).should eq(0)
      File.read(kept).should eq("nested\n")
      File.exists?(cleared).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "uses yt-dlp compatible usage exit status" do
    CrDlp::CLI.run([] of String).should eq(2)
  end

  it "handles preview update checks before requiring URLs" do
    CrDlp::CLI.run(["--update"]).should eq(0)
  end

  it "removes a configured cache directory before requiring URLs" do
    directory = File.join(Dir.tempdir, "cr-dlp-cache-#{Random::Secure.hex(6)}")
    cache = File.join(directory, "cache")
    Dir.mkdir_p(cache)
    begin
      File.write(File.join(cache, "entry"), "cached")

      CrDlp::CLI.run(["--cache-dir", cache, "--rm-cache-dir"]).should eq(0)
      Dir.exists?(cache).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "appends URLs from a batch file before dispatch" do
    directory = File.join(Dir.tempdir, "cr-dlp-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)
    begin
      batch = File.join(directory, "urls.txt")
      output = File.join(directory, "ids.txt")
      File.write(batch, "# comment\n\ncr-dlp:fixture:one\n; another comment\ncr-dlp:fixture:two\n")

      CrDlp::CLI.run([
        "--batch-file", batch,
        "--print-to-file", "id", output,
      ]).should eq(0)
      File.read(output).should eq("one\ntwo\n")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
