require "./spec_helper"
require "db"
require "sqlite3"

{% if flag?(:win32) %}
  lib LibCrypt32
    fun crypt_protect_data = CryptProtectData(
      data_in : DataBlob*,
      data_descr : UInt16*,
      optional_entropy : DataBlob*,
      reserved : Void*,
      prompt_struct : Void*,
      flags : UInt32,
      data_out : DataBlob*,
    ) : Int32
  end

  private def dpapi_protect(data : Bytes) : Bytes
    input = LibCrypt32::DataBlob.new(
      cb_data: data.size.to_u32,
      pb_data: data.to_unsafe,
    )
    output = LibCrypt32::DataBlob.new(cb_data: 0_u32, pb_data: Pointer(UInt8).null)
    ok = LibCrypt32.crypt_protect_data(
      pointerof(input),
      Pointer(UInt16).null,
      Pointer(LibCrypt32::DataBlob).null,
      Pointer(Void).null,
      Pointer(Void).null,
      0_u32,
      pointerof(output),
    )
    raise "CryptProtectData failed" if ok == 0
    result = Bytes.new(output.cb_data.to_i) { |index| output.pb_data[index] }
    LibC.LocalFree(output.pb_data.as(Void*)) unless output.pb_data.null?
    result
  end
{% end %}

private def safari_binarycookies(cookies : Array(Bytes)) : Bytes
  page_header = IO::Memory.new
  page_header.write_bytes(256_u32, IO::ByteFormat::LittleEndian)
  page_header.write_bytes(cookies.size.to_u32, IO::ByteFormat::LittleEndian)
  offset = 12 + cookies.size * 4
  cookies.each do |cookie|
    page_header.write_bytes(offset.to_u32, IO::ByteFormat::LittleEndian)
    offset += cookie.size
  end
  page_header.write_bytes(0_u32, IO::ByteFormat::LittleEndian)

  page = IO::Memory.new
  page.write(page_header.to_slice)
  cookies.each { |cookie| page.write(cookie) }
  page_bytes = page.to_slice

  file = IO::Memory.new
  file.write("cook".to_slice)
  file.write_bytes(1_u32, IO::ByteFormat::BigEndian)
  file.write_bytes(page_bytes.size.to_u32, IO::ByteFormat::BigEndian)
  file.write(page_bytes)
  file.to_slice
end

private def safari_cookie(
  domain : String,
  name : String,
  path : String,
  value : String,
  flags = 0_u32,
  expires_at = 1_893_456_000_i64,
) : Bytes
  header_size = 56
  strings = [domain, name, path, value, "", ""]
  offsets = [] of Int32
  cursor = header_size
  payload = IO::Memory.new
  strings.each do |entry|
    offsets << cursor
    bytes = entry.to_slice
    payload.write(bytes)
    payload.write_byte(0_u8)
    cursor += bytes.size + 1
  end

  cookie = Bytes.new(cursor, 0_u8)
  put_u32_le(cookie, 0, cursor.to_u32)
  put_u32_le(cookie, 8, flags)
  put_u32_le(cookie, 16, offsets[0].to_u32)
  put_u32_le(cookie, 20, offsets[1].to_u32)
  put_u32_le(cookie, 24, offsets[2].to_u32)
  put_u32_le(cookie, 28, offsets[3].to_u32)
  put_u32_le(cookie, 32, offsets[4].to_u32)
  put_u32_le(cookie, 36, offsets[5].to_u32)
  IO::ByteFormat::LittleEndian.encode((expires_at - 978_307_200).to_f64, cookie[40, 8])
  cookie[header_size, payload.size].copy_from(payload.to_slice)
  cookie
end

private def put_u32_le(target : Bytes, offset : Int32, value : UInt32)
  IO::ByteFormat::LittleEndian.encode(value, target[offset, 4])
end

describe CrDlp::BrowserCookies do
  it "parses browser specifications" do
    spec = CrDlp::BrowserCookies.parse_specification("firefox:Default")
    spec.browser.should eq("firefox")
    spec.profile.should eq("Default")
    spec.keyring.should be_nil
    spec.container.should be_nil

    chrome = CrDlp::BrowserCookies.parse_specification("chrome+GNOMEKEYRING:Profile 1")
    chrome.browser.should eq("chrome")
    chrome.keyring.should eq("GNOMEKEYRING")
    chrome.profile.should eq("Profile 1")

    container = CrDlp::BrowserCookies.parse_specification("firefox::Personal")
    container.container.should eq("Personal")

    safari = CrDlp::BrowserCookies.parse_specification("safari:/tmp/Cookies.binarycookies")
    safari.browser.should eq("safari")
    safari.profile.not_nil!.should contain("Cookies.binarycookies")
  end

  it "rejects unsupported browsers and keyrings" do
    expect_raises(CrDlp::UsageError) do
      CrDlp::BrowserCookies.parse_specification("netscape")
    end
    expect_raises(CrDlp::UsageError) do
      CrDlp::BrowserCookies.parse_specification("firefox+INVALID")
    end
  end

  it "extracts cookies from a Firefox profile database" do
    directory = File.join(Dir.tempdir, "cr-dlp-firefox-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    database = File.join(directory, "cookies.sqlite")
    begin
      uri = "sqlite3:///#{File.expand_path(database).gsub('\\', '/')}"
      DB.open(uri) do |db|
        db.exec <<-SQL
          CREATE TABLE moz_cookies (
            id INTEGER PRIMARY KEY,
            originAttributes TEXT,
            host TEXT,
            name TEXT,
            value TEXT,
            path TEXT,
            expiry INTEGER,
            lastAccessed INTEGER,
            creationTime INTEGER,
            isSecure INTEGER,
            isHttpOnly INTEGER
          )
        SQL
        db.exec(
          "INSERT INTO moz_cookies VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          1, "", "127.0.0.1", "session", "fixture", "/", 0, 0, 0, 0, 0,
        )
      end

      row_count = 0_i64
      DB.open(uri) do |db|
        db.query("SELECT COUNT(*) FROM moz_cookies") do |rs|
          rs.each { row_count = rs.read(Int64) }
        end
      end
      row_count.should eq(1)

      jar = CrDlp::BrowserCookies.extract("firefox:#{directory}")
      jar.size.should eq(1)
      jar.header_for("http://127.0.0.1/").should eq("session=fixture")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "extracts cookies from a Safari binarycookies file" do
    directory = File.join(Dir.tempdir, "cr-dlp-safari-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    cookie_file = File.join(directory, "Cookies.binarycookies")
    begin
      File.write(cookie_file, safari_binarycookies([
        safari_cookie(".example.test", "sid", "watch", "secure", flags: 5_u32),
        safari_cookie("example.test", "plain", "/", "ok"),
      ]))

      jar = CrDlp::BrowserCookies.extract("safari:#{cookie_file}")
      jar.size.should eq(2)
      jar.header_for("https://sub.example.test/watch/page").should eq("sid=secure")
      jar.header_for("http://example.test/").should eq("plain=ok")
      jar.cookies.find(&.name.==("sid")).not_nil!.http_only.should be_true
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  {% if flag?(:win32) %}
    it "decrypts modern Chromium AES-GCM cookies with the DPAPI Local State key" do
      directory = File.join(Dir.tempdir, "cr-dlp-chromium-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      database = File.join(directory, "Cookies")
      begin
        key = Bytes.new(32) { |index| (index + 1).to_u8 }
        protected_key = dpapi_protect(key)
        File.write(File.join(directory, "Local State"), {
          "os_crypt" => {
            "encrypted_key" => Base64.strict_encode("DPAPI".to_slice + protected_key),
          },
        }.to_json)

        host = "127.0.0.1"
        plaintext = Digest::SHA256.digest(host) + "fixture".to_slice
        nonce = Bytes.new(12) { |index| (0xa0 + index).to_u8 }
        encrypted, tag = CrDlp::AES.aes_gcm_encrypt_and_tag(plaintext, key, nonce)
        encrypted_value = "v10".to_slice + nonce + encrypted + tag

        uri = "sqlite3:///#{File.expand_path(database).gsub('\\', '/')}"
        DB.open(uri) do |db|
          db.exec("CREATE TABLE meta (key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)")
          db.exec("INSERT INTO meta VALUES ('version', '24')")
          db.exec <<-SQL
            CREATE TABLE cookies (
              host_key TEXT,
              name TEXT,
              value TEXT,
              encrypted_value BLOB,
              path TEXT,
              expires_utc INTEGER,
              is_secure INTEGER
            )
          SQL
          db.exec(
            "INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?)",
            host, "session", "", encrypted_value, "/", 0_i64, 0_i64,
          )
        end

        jar = CrDlp::BrowserCookies.extract("chrome:#{directory}")
        jar.header_for("http://127.0.0.1/").should eq("session=fixture")
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  {% end %}
end
