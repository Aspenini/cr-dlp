require "./spec_helper"
require "http/server"

private def with_hls_server(&block : String ->)
  attempts = Atomic(Int32).new(0)
  live_requests = Atomic(Int32).new(0)
  live_resume_requests = Atomic(Int32).new(0)
  key = Bytes[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  iv = Bytes.new(16, 0_u8)
  encrypted = begin
    cipher = OpenSSL::Cipher.new("aes-128-cbc")
    cipher.encrypt
    cipher.key = key
    cipher.iv = iv
    io = IO::Memory.new
    io.write(cipher.update("secret".to_slice))
    io.write(cipher.final)
    io.to_slice
  end

  server = HTTP::Server.new do |context|
    case context.request.path
    when "/master.m3u8"
      context.response.content_type = "application/vnd.apple.mpegurl"
      context.response.print <<-'M3U8'
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=320x180
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=640x360
        high.m3u8
        M3U8
    when "/low.m3u8"
      context.response.print("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nlow.ts\n#EXT-X-ENDLIST\n")
    when "/high.m3u8"
      context.response.print <<-'M3U8'
        #EXTM3U
        #EXT-X-TARGETDURATION:1
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:1,
        slow.ts
        #EXTINF:1,
        retry.ts
        #EXT-X-ENDLIST
        M3U8
    when "/resume.m3u8"
      context.response.print("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\na.ts\n#EXTINF:1,\nb.ts\n#EXT-X-ENDLIST\n")
    when "/aes.m3u8"
      context.response.print <<-'M3U8'
        #EXTM3U
        #EXT-X-TARGETDURATION:1
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000000
        #EXTINF:1,
        encrypted.ts
        #EXT-X-ENDLIST
        M3U8
    when "/live.m3u8"
      request = live_requests.add(1)
      if request < 2
        context.response.print <<-'M3U8'
          #EXTM3U
          #EXT-X-TARGETDURATION:0.05
          #EXT-X-MEDIA-SEQUENCE:10
          #EXTINF:1,
          a.ts
          #EXTINF:1,
          b.ts
          M3U8
      else
        context.response.print <<-'M3U8'
          #EXTM3U
          #EXT-X-TARGETDURATION:0.05
          #EXT-X-MEDIA-SEQUENCE:11
          #EXTINF:1,
          b.ts
          #EXTINF:1,
          c.ts
          #EXT-X-ENDLIST
          M3U8
      end
    when "/live-resume.m3u8"
      request = live_resume_requests.add(1)
      if request < 2
        context.response.print <<-'M3U8'
          #EXTM3U
          #EXT-X-TARGETDURATION:0.05
          #EXT-X-MEDIA-SEQUENCE:10
          #EXTINF:1,
          a.ts
          #EXTINF:1,
          b.ts
          M3U8
      else
        context.response.print <<-'M3U8'
          #EXTM3U
          #EXT-X-TARGETDURATION:0.05
          #EXT-X-MEDIA-SEQUENCE:11
          #EXTINF:1,
          b.ts
          #EXTINF:1,
          c.ts
          #EXT-X-ENDLIST
          M3U8
      end
    when "/init.mp4"
      context.response.write("INIT".to_slice)
    when "/slow.ts"
      sleep 20.milliseconds
      context.response.write("A".to_slice)
    when "/retry.ts"
      if attempts.add(1) == 0
        context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
      else
        context.response.write("B".to_slice)
      end
    when "/low.ts"
      context.response.write("LOW".to_slice)
    when "/a.ts"
      context.response.write("A".to_slice)
    when "/b.ts"
      context.response.write("B".to_slice)
    when "/c.ts"
      context.response.write("C".to_slice)
    when "/key.bin"
      context.response.write(key)
    when "/encrypted.ts"
      context.response.write(encrypted)
    else
      context.response.status = HTTP::Status::NOT_FOUND
    end
  end
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  begin
    yield "http://127.0.0.1:#{address.port}"
  ensure
    server.close
  end
end

describe CrDlp::Manifest::Hls do
  it "parses the upstream Apple master fixtures" do
    bipbop_url = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8"
    bipbop = CrDlp::Manifest::Hls::Parser.parse(
      File.read("test/testdata/m3u8/bipbop_16x9.m3u8"),
      bipbop_url,
    )
    bipbop.media.should be_false
    bipbop.variants.size.should eq(6)
    bipbop.renditions.count(&.media_type.==("AUDIO")).should eq(2)
    bipbop.subtitles.keys.sort.should eq(["en", "es", "fr", "ja"])
    bipbop.best_variant.not_nil!.height.should eq(1080)

    advanced = CrDlp::Manifest::Hls::Parser.parse(
      File.read("test/testdata/m3u8/img_bipbop_adv_example_fmp4.m3u8"),
      "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
    )
    advanced.variants.size.should eq(24)
    advanced.renditions.count(&.media_type.==("AUDIO")).should eq(3)
    advanced.best_variant.not_nil!.effective_bandwidth.should eq(8_190_919)
  end

  it "parses initialization fragments, byte ranges, and encryption state" do
    playlist = CrDlp::Manifest::Hls::Parser.parse(<<-'M3U8', "https://example.test/path/media.m3u8")
      #EXTM3U
      #EXT-X-TARGETDURATION:4
      #EXT-X-MEDIA-SEQUENCE:9
      #EXT-X-MAP:URI="init.mp4",BYTERANGE="4@1"
      #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x01
      #EXT-X-BYTERANGE:3@5
      #EXTINF:4,
      media.bin
      #EXT-X-BYTERANGE:2
      #EXTINF:2,
      media.bin
      #EXT-X-ENDLIST
      M3U8

    playlist.media.should be_true
    playlist.end_list.should be_true
    playlist.fragments.size.should eq(3)
    playlist.fragments[0].initialization.should be_true
    playlist.fragments[0].byte_range.not_nil!.header.should eq("bytes=1-4")
    playlist.fragments[1].byte_range.not_nil!.header.should eq("bytes=5-7")
    playlist.fragments[2].byte_range.not_nil!.header.should eq("bytes=8-9")
    playlist.fragments[1].media_sequence.should eq(9)
    playlist.fragments[1].encryption.not_nil!.key_url.should eq("https://example.test/path/key.bin")
  end

  it "selects the best variant and downloads fragments in manifest order" do
    with_hls_server do |base_url|
      Dir.cd(Dir.tempdir) do
        directory = "cr-dlp-hls-#{Random::Secure.hex(6)}"
        Dir.mkdir(directory)
        begin
          output = File.join(directory, "%(id)s.%(ext)s")
          options = CrDlp::ParsedOptions.new({
            "outtmpl"                       => JSON::Any.new({"default" => JSON::Any.new(output)}),
            "concurrent_fragment_downloads" => JSON::Any.new(3_i64),
            "fragment_retries"              => JSON::Any.new(1_i64),
            "fixup"                         => JSON::Any.new("never"),
          })
          info = CrDlp::Client.new(options).extract_info("#{base_url}/master.m3u8")

          info.string?("manifest_url").should eq("#{base_url}/master.m3u8")
          info.int?("height").should eq(360)
          File.read(File.join(directory, "master.mp4")).should eq("INITAB")
        ensure
          FileUtils.rm_rf(directory)
        end
      end
    end
  end

  it "downloads every selected variant for the all selector" do
    with_hls_server do |base_url|
      directory = File.join(Dir.tempdir, "cr-dlp-hls-all-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      begin
        options = CrDlp::ParsedOptions.new({
          "format"  => JSON::Any.new("all"),
          "fixup"   => JSON::Any.new("never"),
          "outtmpl" => JSON::Any.new({
            "default" => JSON::Any.new(File.join(directory, "%(format_id)s.%(ext)s")),
          }),
          "fragment_retries" => JSON::Any.new(1_i64),
        })
        info = CrDlp::Client.new(options).extract_info("#{base_url}/master.m3u8")

        selections = info.sidecar["format_selections"].as(CrDlp::FormatSelections)
        selections.infos.map(&.string?("format_id")).should eq(["200", "100"])
        File.read(File.join(directory, "200.mp4")).should eq("INITAB")
        File.read(File.join(directory, "100.mp4")).should eq("LOW")
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end

  it "resumes media playlists and decrypts AES-128 fragments" do
    with_hls_server do |base_url|
      directory = File.join(Dir.tempdir, "cr-dlp-hls-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      begin
        output = File.join(directory, "%(id)s.%(ext)s")
        options = CrDlp::ParsedOptions.new({
          "outtmpl"    => JSON::Any.new({"default" => JSON::Any.new(output)}),
          "continuedl" => JSON::Any.new(true),
          "fixup"      => JSON::Any.new("never"),
        })
        client = CrDlp::Client.new(options)

        resume_file = File.join(directory, "resume.mp4")
        File.write("#{resume_file}.part", "A")
        File.write("#{resume_file}.ytdl", {"fragment_index" => 1, "fragment_count" => 2}.to_json)
        client.extract_info("#{base_url}/resume.m3u8")
        File.read(resume_file).should eq("AB")

        client.extract_info("#{base_url}/aes.m3u8")
        File.read(File.join(directory, "aes.mp4")).should eq("secret")
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end

  it "refreshes live playlists, deduplicates sliding windows, and resumes by fragment identity" do
    with_hls_server do |base_url|
      directory = File.join(Dir.tempdir, "cr-dlp-hls-live-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      begin
        options = CrDlp::ParsedOptions.new({
          "outtmpl" => JSON::Any.new({
            "default" => JSON::Any.new(File.join(directory, "%(id)s.%(ext)s")),
          }),
          "fixup" => JSON::Any.new("never"),
        })
        client = CrDlp::Client.new(options)
        client.extract_info("#{base_url}/live.m3u8")
        File.read(File.join(directory, "live.mp4")).should eq("ABC")

        resume_file = File.join(directory, "live-resume.mp4")
        File.write("#{resume_file}.part", "A")
        File.write("#{resume_file}.ytdl", {
          "fragment_keys" => ["media:10:#{base_url}/a.ts:"],
        }.to_json)
        client.extract_info("#{base_url}/live-resume.m3u8")
        File.read(resume_file).should eq("ABC")
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end
end
