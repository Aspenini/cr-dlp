require "./spec_helper"

private class ArchiveOrgFixtureHandler < CrDlp::Networking::RequestHandler
  METADATA = {
    "metadata" => {
      "identifier"  => "FixtureArchive",
      "title"       => "Fixture Archive",
      "description" => "<p>Fixture <b>description</b></p>",
      "uploader"    => "tester@example.com",
      "publicdate"  => "2024-01-02 03:04:05",
      "creator"     => ["Test Creator"],
    },
    "files" => [
      {
        "name"   => "first.mp4",
        "format" => "MPEG4",
        "source" => "original",
        "width"  => "640",
        "height" => "360",
        "length" => "2.5",
        "size"   => "5",
      },
      {
        "name"     => "first.ogv",
        "original" => "first.mp4",
        "format"   => "Ogg Video",
        "source"   => "derivative",
        "width"    => "320",
        "height"   => "180",
        "length"   => "2.5",
        "size"     => "4",
      },
      {
        "name"     => "thumbs/first.jpg",
        "original" => "first.mp4",
        "format"   => "Thumbnail",
        "size"     => "3",
      },
      {
        "name"   => "second.mp3",
        "format" => "VBR MP3",
        "source" => "original",
        "length" => "0:03",
        "size"   => "6",
      },
    ],
  }.to_json

  PLAYLIST = <<-'HTML'
    <html><play-av playlist='[
      {"title":"First Video","orig":"first.mp4","duration":2.5},
      {"title":"Second Audio","orig":"second.mp3","duration":3}
    ]'></play-av></html>
    HTML

  def key : String
    "ArchiveOrgFixture"
  end

  def supports?(request : CrDlp::Networking::Request) : Bool
    URI.parse(request.url).host == "archive.org"
  end

  def send(request : CrDlp::Networking::Request) : CrDlp::Networking::Response
    body = case URI.parse(request.url).path
           when "/metadata/FixtureArchive"            then METADATA
           when "/embed/FixtureArchive"               then PLAYLIST
           when "/download/FixtureArchive/first.mp4"  then "VIDEO"
           when "/download/FixtureArchive/second.mp3" then "AUDIO!"
           else
             raise CrDlp::HttpError.new(404, request.url)
           end
    CrDlp::Networking::Response.new(
      request.url,
      200,
      {"Content-Length" => body.bytesize.to_s},
      body.to_slice,
    )
  end
end

private def archive_client(options = CrDlp::ParsedOptions.new) : CrDlp::Client
  director = CrDlp::Networking::RequestDirector.new(
    [ArchiveOrgFixtureHandler.new] of CrDlp::Networking::RequestHandler
  )
  CrDlp::Client.new(options, request_director: director)
end

describe CrDlp::ArchiveOrgExtractor do
  it "matches before Generic and extracts an explicitly selected file" do
    client = archive_client
    client.extractor_registry.keys.should eq(["Fixture", "ArchiveOrg", "Generic"])
    info = client.extract_info(
      "https://archive.org/details/FixtureArchive/first.mp4",
      download: false,
    )

    info.id.should eq("FixtureArchive/first.mp4")
    info.title.should eq("first.mp4")
    info.string?("display_id").should eq("first.mp4")
    info.string?("extractor_key").should eq("ArchiveOrg")
    info.string?("url").should eq("https://archive.org/download/FixtureArchive/first.mp4")
    info.string?("ext").should eq("mp4")
    info.int?("height").should eq(360)
    info.float?("duration").should eq(2.5)
    info.formats.size.should eq(2)
    info.array?("thumbnails").not_nil!.size.should eq(1)
  end

  it "processes multi-entry items with playlist selection and safe filenames" do
    directory = File.join(Dir.tempdir, "cr-dlp-archive-org-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      options = CrDlp::ParsedOptions.new({
        "playlist_items" => JSON::Any.new("2"),
        "outtmpl"        => JSON::Any.new({
          "default" => JSON::Any.new(File.join(directory, "%(playlist_index)s-%(title)s.%(ext)s")),
        }),
      })
      info = archive_client(options).extract_info(
        "https://archive.org/details/FixtureArchive"
      )

      info.string?("_type").should eq("playlist")
      entries = info.array?("entries").not_nil!
      entries.size.should eq(1)
      entry = entries.first.as_h
      entry["id"].as_s.should eq("FixtureArchive/second.mp3")
      entry["playlist_index"].as_i.should eq(2)
      File.read(File.join(directory, "2-second.mp3.mp3")).should eq("AUDIO!")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
