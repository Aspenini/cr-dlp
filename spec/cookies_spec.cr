require "./spec_helper"

describe CrDlp::CookieJar do
  it "loads Netscape cookies and applies domain, path, secure, and expiry rules" do
    directory = File.join(Dir.tempdir, "cr-dlp-cookies-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    path = File.join(directory, "cookies.txt")
    begin
      File.write(path, <<-TEXT)
      # Netscape HTTP Cookie File
      #HttpOnly_.example.com	TRUE	/restricted	TRUE	4102444800	secure_token	secret
      example.com	FALSE	/	FALSE	0	session	root
      example.com	FALSE	/	FALSE	1	expired	gone
      TEXT

      jar = CrDlp::CookieJar.load(path)
      jar.header_for("http://example.com/").should eq("session=root")
      jar.header_for("https://sub.example.com/restricted/video").should eq("secure_token=secret")
      jar.header_for("wss://sub.example.com/restricted/socket").should eq("secure_token=secret")
      jar.header_for("ws://sub.example.com/restricted/socket").should be_nil
      jar.header_for("https://other.test/restricted/video").should be_nil
      jar.size.should eq(2)
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "stores response cookies and round trips the Netscape file" do
    directory = File.join(Dir.tempdir, "cr-dlp-cookies-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    path = File.join(directory, "cookies.txt")
    begin
      jar = CrDlp::CookieJar.load(path)
      headers = HTTP::Headers.new
      headers.add("Set-Cookie", "root=value; Path=/; HttpOnly")
      headers.add("Set-Cookie", "scoped=path; Secure")
      jar.store(headers, "https://media.example.com/videos/index")

      jar.header_for("https://media.example.com/videos/file").should eq("scoped=path; root=value")
      jar.header_for("http://media.example.com/videos/file").should eq("root=value")

      reloaded = CrDlp::CookieJar.load(path)
      reloaded.header_for("https://media.example.com/videos/file").should eq("scoped=path; root=value")
      File.read(path).should contain("#HttpOnly_media.example.com")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "removes cookies expired by a Set-Cookie response" do
    jar = CrDlp::CookieJar.new
    jar.add(CrDlp::CookieJar::Cookie.new(
      "example.com",
      false,
      "/",
      false,
      nil,
      "session",
      "value",
    ))
    headers = HTTP::Headers{"Set-Cookie" => "session=deleted; Path=/; Max-Age=0"}
    jar.store(headers, "https://example.com/")

    jar.header_for("https://example.com/").should be_nil
  end
end
