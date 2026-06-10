require "./spec_helper"

private class ArchiveFailingDownloader < CrDlp::Downloader
  def protocols : Array(String)
    ["archive-failure"]
  end

  def download(info : CrDlp::Info, filename : String) : String
    raise CrDlp::DownloadError.new("planned failure")
  end
end

private def archive_options(path : String, output : String) : CrDlp::ParsedOptions
  CrDlp::ParsedOptions.new({
    "download_archive" => JSON::Any.new(path),
    "outtmpl"          => JSON::Any.new({"default" => JSON::Any.new(output)}),
  })
end

describe CrDlp::DownloadArchive do
  it "uses compatible IDs, preloads entries, and accepts old archive IDs" do
    directory = File.join(Dir.tempdir, "cr-dlp-archive-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      path = File.join(directory, "archive.txt")
      File.write(path, "generic old-id\n\n")
      archive = CrDlp::DownloadArchive.new(path)

      info = CrDlp::Info.new
      info["id"] = "new-id"
      info["extractor_key"] = "Generic"
      info["_old_archive_ids"] = JSON::Any.new([JSON::Any.new("generic old-id")])
      CrDlp::DownloadArchive.id(info).should eq("generic new-id")
      archive.includes?(info).should be_true

      archive.record(info)
      archive.record(info)
      File.read(path).lines.count(&.==("generic new-id")).should eq(1)
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "records successful downloads and skips archived entries" do
    directory = File.join(Dir.tempdir, "cr-dlp-archive-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      path = File.join(directory, "archive.txt")
      output = File.join(directory, "%(id)s.%(ext)s")
      first = CrDlp::Client.new(archive_options(path, output))
      first.extract_info("cr-dlp:fixture:done")
      File.read(path).should eq("fixture done\n")

      downloaded = File.join(directory, "done.txt")
      File.delete(downloaded)
      second = CrDlp::Client.new(archive_options(path, output))
      info = second.extract_info("cr-dlp:fixture:done")
      File.exists?(downloaded).should be_false
      info.sidecar["archive_status"].as(CrDlp::ArchiveStatus).skipped.should be_true
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "does not record failed downloads" do
    directory = File.join(Dir.tempdir, "cr-dlp-archive-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      path = File.join(directory, "archive.txt")
      options = archive_options(path, File.join(directory, "%(id)s.%(ext)s"))
      client = CrDlp::Client.new(options)
      client.downloader_registry.register(["archive-failure"]) do |owner|
        ArchiveFailingDownloader.new(owner)
      end
      info = CrDlp::Info.new
      info["id"] = "failed"
      info["title"] = "failed"
      info["url"] = "archive-failure://failed"
      info["protocol"] = "archive-failure"
      info["extractor_key"] = "Fixture"
      info["ext"] = "bin"

      expect_raises(CrDlp::DownloadError, "planned failure") do
        client.process_info(info)
      end
      File.exists?(path).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "can force archive writes during simulation" do
    directory = File.join(Dir.tempdir, "cr-dlp-archive-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      path = File.join(directory, "archive.txt")
      options = CrDlp::ParsedOptions.new({
        "download_archive"             => JSON::Any.new(path),
        "simulate"                     => JSON::Any.new(true),
        "force_write_download_archive" => JSON::Any.new(true),
      })
      CrDlp::Client.new(options).download(["cr-dlp:fixture:simulated"]).should eq(0)
      File.read(path).should eq("fixture simulated\n")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
