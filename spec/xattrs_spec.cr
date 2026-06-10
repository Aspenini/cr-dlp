require "./spec_helper"

private class RecordingXAttrWriter < CrDlp::XAttrWriter
  getter writes = [] of Tuple(String, String, String)

  def initialize(@failure : CrDlp::XAttrWriteError? = nil)
  end

  def write(path : String, key : String, value : String)
    raise @failure.not_nil! if @failure
    @writes << {path, key, value}
  end
end

private def xattr_info(path : String) : CrDlp::Info
  CrDlp::Info.new({
    "id"          => JSON::Any.new("xattr"),
    "title"       => JSON::Any.new("Metadata Title"),
    "filepath"    => JSON::Any.new(path),
    "webpage_url" => JSON::Any.new("https://example.test/watch"),
    "upload_date" => JSON::Any.new("20260607"),
    "uploader"    => JSON::Any.new("Uploader"),
    "format"      => JSON::Any.new("mp4"),
    "description" => JSON::Any.new("Description"),
  })
end

describe CrDlp::XAttrMetadataPostProcessor do
  it "writes mapped metadata, hyphenates dates, and preserves mtime" do
    path = File.tempname("cr-dlp-xattr", ".mp4")
    begin
      File.write(path, "MEDIA")
      original_time = Time.utc(2020, 1, 2, 3, 4, 5)
      File.utime(original_time, original_time, path)
      writer = RecordingXAttrWriter.new
      client = CrDlp::Client.new(xattr_writer: writer, auto_init: false)

      CrDlp::XAttrMetadataPostProcessor.new(client).run(xattr_info(path))

      values = writer.writes.to_h { |_, key, value| {key, value} }
      values["user.xdg.referrer.url"].should eq("https://example.test/watch")
      values["user.dublincore.title"].should eq("Metadata Title")
      values["user.dublincore.date"].should eq("2026-06-07")
      values["user.dublincore.contributor"].should eq("Uploader")
      values["user.dublincore.description"].should eq("Description")
      File.info(path).modification_time.to_unix.should eq(original_time.to_unix)
    ensure
      File.delete?(path)
    end
  end

  it "warns for capacity failures and rejects unsupported filesystems" do
    path = File.tempname("cr-dlp-xattr", ".mp4")
    begin
      File.write(path, "MEDIA")
      no_space = RecordingXAttrWriter.new(CrDlp::XAttrWriteError.new(
        "quota",
        CrDlp::XAttrFailureReason::NoSpace,
      ))
      CrDlp::XAttrMetadataPostProcessor.new(
        CrDlp::Client.new(xattr_writer: no_space, auto_init: false),
      ).run(xattr_info(path))

      unsupported = RecordingXAttrWriter.new(CrDlp::XAttrWriteError.new(
        "not supported",
        CrDlp::XAttrFailureReason::Unsupported,
      ))
      expect_raises(CrDlp::PostProcessingError, "doesn't support") do
        CrDlp::XAttrMetadataPostProcessor.new(
          CrDlp::Client.new(xattr_writer: unsupported, auto_init: false),
        ).run(xattr_info(path))
      end
    ensure
      File.delete?(path)
    end
  end

  it "writes real NTFS alternate data streams on Windows" do
    {% if flag?(:win32) %}
      path = File.tempname("cr-dlp-xattr", ".mp4")
      begin
        File.write(path, "MEDIA")
        writer = CrDlp::SystemXAttrWriter.new(CrDlp::SystemProcessRunner.new)
        writer.write(path, "user.dublincore.title", "Real title")
        File.read("#{path}:user.dublincore.title").should eq("Real title")
      ensure
        File.delete?(path)
      end
    {% else %}
      pending!("NTFS alternate data streams are Windows-specific")
    {% end %}
  end
end
