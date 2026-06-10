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

  it "uses yt-dlp compatible usage exit status" do
    CrDlp::CLI.run([] of String).should eq(2)
  end
end
