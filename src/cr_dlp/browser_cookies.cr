require "db"
require "sqlite3"
require "base64"
require "file_utils"

{% if flag?(:win32) %}
  @[Link("Crypt32")]
  lib LibCrypt32
    struct DataBlob
      cb_data : UInt32
      pb_data : UInt8*
    end

    fun crypt_unprotect_data = CryptUnprotectData(
      data_in : DataBlob*,
      data_descr : Void*,
      optional_entropy : DataBlob*,
      reserved : Void*,
      prompt_struct : Void*,
      flags : UInt32,
      data_out : DataBlob*,
    ) : Int32
  end
{% end %}

module CrDlp
  module BrowserCookies
    extend self

    CHROMIUM_BROWSERS             = %w(brave chrome chromium edge opera vivaldi whale).to_set
    SUPPORTED_BROWSERS            = CHROMIUM_BROWSERS | %w(firefox safari).to_set
    SUPPORTED_KEYRINGS            = %w(BASICTEXT GNOMEKEYRING KWALLET KWALLET5 KWALLET6).to_set
    MAX_FIREFOX_DB_SCHEMA_VERSION = 17

    record Specification,
      browser : String,
      profile : String?,
      keyring : String?,
      container : String?

    def parse_specification(spec : String) : Specification
      source = spec.strip
      container = nil
      if split = source.rindex("::")
        container = source[(split + 2)..]?.presence
        source = source[0...split]
      end

      browser_name = source
      keyring = nil
      profile = nil
      if plus = source.index('+')
        browser_name = source[0...plus]
        remainder = source[(plus + 1)..]
        if colon = remainder.index(':')
          keyring = remainder[0...colon]
          profile = remainder[(colon + 1)..]?.presence
        else
          keyring = remainder.presence
        end
      elsif colon = source.index(':')
        browser_name = source[0...colon]
        profile = source[(colon + 1)..]?.presence
      end

      browser = browser_name.strip.downcase
      raise UsageError.new("invalid cookies from browser arguments: #{spec}") if browser.empty?
      unless browser.in?(SUPPORTED_BROWSERS)
        supported = SUPPORTED_BROWSERS.to_a.sort!.join(", ")
        raise UsageError.new(
          "unsupported browser specified for cookies: \"#{browser}\". Supported browsers are: #{supported}"
        )
      end
      keyring = keyring.try(&.strip.upcase)
      if keyring && !keyring.in?(SUPPORTED_KEYRINGS)
        supported = SUPPORTED_KEYRINGS.to_a.sort!.join(", ")
        raise UsageError.new(
          "unsupported keyring specified for cookies: \"#{keyring}\". Supported keyrings are: #{supported}"
        )
      end
      Specification.new(
        browser: browser,
        profile: profile.try(&.strip),
        keyring: keyring,
        container: container.try(&.strip),
      )
    end

    def extract(spec : String) : CookieJar
      parsed = parse_specification(spec)
      case parsed.browser
      when "firefox"
        extract_firefox(parsed.profile, parsed.container)
      when "safari"
        extract_safari(parsed.profile)
      else
        extract_chromium(parsed.browser, parsed.profile, parsed.keyring)
      end
    end

    def extract_firefox(profile : String?, container : String?) : CookieJar
      search_roots = firefox_search_roots(profile)
      database_path = newest(firefox_cookie_databases(search_roots))
      unless database_path
        raise RequestError.new("could not find firefox cookies database in #{search_roots.join(", ")}")
      end

      container_id = resolve_firefox_container(database_path, container) if container
      jar = CookieJar.new
      with_database_copy(database_path) do |db|
        schema_version = db.scalar("PRAGMA user_version").as(Int64)
        STDERR.puts(
          "WARNING: Possibly unsupported firefox cookies database version: #{schema_version}"
        ) if schema_version > MAX_FIREFOX_DB_SCHEMA_VERSION

        query, args = firefox_cookie_query(container, container_id)
        db.query(query, args: args) do |rs|
          rs.each do
            host = rs.read(String)
            name = rs.read(String)
            value = rs.read(String)
            path = rs.read(String)
            expiry = rs.read(Int64?)
            is_secure = rs.read(Int64) != 0
            expires_at = expiry
            if expires_at && schema_version >= 16
              expires_at = expires_at // 1000
            end
            expires_at = nil if expires_at == 0
            jar.add(CookieJar::Cookie.new(
              normalize_domain(host),
              host.starts_with?('.'),
              normalize_path(path),
              is_secure,
              expires_at,
              name,
              value,
            ))
          end
        end
      end
      jar
    end

    def extract_safari(profile : String?) : CookieJar
      search_paths = safari_cookie_files(profile)
      cookie_path = newest(search_paths)
      unless cookie_path
        raise RequestError.new("could not find Safari Cookies.binarycookies in #{search_paths.join(", ")}")
      end
      parse_safari_binarycookies(cookie_path)
    end

    def extract_chromium(browser : String, profile : String?, keyring : String?) : CookieJar
      config = chromium_settings(browser)
      search_root = chromium_search_root(config, profile)
      database_path = newest(find_files(search_root, "Cookies"))
      unless database_path
        raise RequestError.new("could not find #{browser} cookies database in \"#{search_root}\"")
      end

      jar = CookieJar.new
      with_database_copy(database_path) do |db|
        meta_version = db.scalar("SELECT value FROM meta WHERE key = 'version'").as(String).to_i
        decryptor = ChromiumCookieDecryptor.new(
          chromium_decryption_root(config, profile, search_root),
          config.keyring_name,
          keyring,
          meta_version,
        )
        secure_column = table_columns(db, "cookies").includes?("is_secure") ? "is_secure" : "secure"
        db.query(
          "SELECT host_key, name, value, encrypted_value, path, expires_utc, #{secure_column} FROM cookies"
        ) do |rs|
          rs.each do
            host = read_blob_or_string(rs)
            name = read_blob_or_string(rs)
            value = read_blob_or_string(rs)
            encrypted = read_blob(rs)
            path = read_blob_or_string(rs)
            expires_utc = rs.read(Int64?)
            is_secure = rs.read(Int64) != 0
            if value.empty? && !encrypted.empty?
              value = decryptor.decrypt(encrypted) || next
            end
            expires_at = expires_utc.nil? || expires_utc == 0 ? nil : expires_utc
            jar.add(CookieJar::Cookie.new(
              normalize_domain(host),
              host.starts_with?('.'),
              normalize_path(path),
              is_secure,
              expires_at,
              name,
              value,
            ))
          end
        end
      end
      jar
    end

    private def firefox_cookie_query(container : String?, container_id : Int32?) : Tuple(String, Array(DB::Any))
      if container_id
        {
          "SELECT host, name, value, path, expiry, isSecure FROM moz_cookies " \
          "WHERE originAttributes LIKE ? OR originAttributes LIKE ?",
          ["%userContextId=#{container_id}", "%userContextId=#{container_id}&%"] of DB::Any,
        }
      elsif container == "none"
        {
          "SELECT host, name, value, path, expiry, isSecure FROM moz_cookies " \
          "WHERE NOT INSTR(originAttributes, 'userContextId=')",
          [] of DB::Any,
        }
      else
        {
          "SELECT host, name, value, path, expiry, isSecure FROM moz_cookies",
          [] of DB::Any,
        }
      end
    end

    private def resolve_firefox_container(database_path : String, container : String?) : Int32?
      return unless container
      return if container == "none"

      containers_path = File.join(File.dirname(database_path), "containers.json")
      raise RequestError.new("could not read containers.json") unless File.exists?(containers_path)
      identities = JSON.parse(File.read(containers_path))["identities"].as_a
      container_id = identities.compact_map do |entry|
        name = entry["name"]?.try(&.as_s)
        next name == container ? entry["userContextId"]?.try(&.as_i) : nil
        l10n = entry["l10nID"]?.try(&.as_s)
        if l10n && (match = l10n.match(/^userContext([^\.]+)\.label$/))
          next container == match[1] ? entry["userContextId"]?.try(&.as_i) : nil
        end
        nil
      end.first?
      raise UsageError.new("could not find firefox container \"#{container}\" in containers.json") unless container_id
      container_id
    end

    private def firefox_search_roots(profile : String?) : Array(String)
      if profile.nil?
        firefox_browser_dirs
      elsif profile_path?(profile)
        [File.expand_path(profile)]
      else
        firefox_browser_dirs.map { |root| File.join(root, profile) }
      end
    end

    private def firefox_browser_dirs : Array(String)
      {% if flag?(:win32) %}
        [
          ENV["APPDATA"]? && File.join(ENV["APPDATA"], "Mozilla", "Firefox", "Profiles"),
          ENV["LOCALAPPDATA"]? &&
            File.join(
              ENV["LOCALAPPDATA"],
              "Packages", "Mozilla.Firefox_n80bbvh6b1yt2", "LocalCache", "Roaming",
              "Mozilla", "Firefox", "Profiles"
            ),
        ].compact
      {% elsif flag?(:darwin) %}
        [File.expand_path("~/Library/Application Support/Firefox/Profiles")]
      {% else %}
        config_home = ENV["XDG_CONFIG_HOME"]? || File.expand_path("~/.config")
        [
          File.join(config_home, "mozilla", "firefox"),
          File.expand_path("~/.mozilla/firefox"),
          File.expand_path("~/.var/app/org.mozilla.firefox/config/mozilla/firefox"),
          File.expand_path("~/.var/app/org.mozilla.firefox/.mozilla/firefox"),
          File.expand_path("~/snap/firefox/common/.mozilla/firefox"),
        ]
      {% end %}
    end

    private def firefox_cookie_databases(roots : Array(String)) : Array(String)
      roots.flat_map do |root|
        next [] of String unless root && Dir.exists?(root)
        files = [] of String
        direct = File.join(root, "cookies.sqlite")
        files << direct if File.exists?(direct)
        Dir.glob(File.join(root, "**", "cookies.sqlite")) { |path| files << path }
        files.uniq
      end
    end

    private def safari_cookie_files(profile : String?) : Array(String)
      if profile
        expanded = File.expand_path(profile)
        return [expanded] if File.file?(expanded)
        if Dir.exists?(expanded)
          direct = File.join(expanded, "Cookies.binarycookies")
          files = [] of String
          files << direct if File.exists?(direct)
          Dir.glob(File.join(expanded, "**", "Cookies.binarycookies")) { |path| files << path }
          return files.uniq
        end
        return [expanded]
      end

      {% if flag?(:darwin) %}
        [
          File.expand_path("~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
          File.expand_path("~/Library/Cookies/Cookies.binarycookies"),
        ]
      {% else %}
        [] of String
      {% end %}
    end

    private def parse_safari_binarycookies(path : String) : CookieJar
      data = File.read(path).to_slice
      raise RequestError.new("Invalid Safari cookie file") unless data.size >= 8 && String.new(data[0, 4]) == "cook"
      page_count = read_u32_be(data, 4).to_i
      page_table_end = 8 + page_count * 4
      raise RequestError.new("Invalid Safari cookie page table") if data.size < page_table_end
      page_sizes = page_count.times.map { |index| read_u32_be(data, 8 + index * 4).to_i }.to_a
      cursor = page_table_end
      jar = CookieJar.new
      page_sizes.each do |page_size|
        raise RequestError.new("Invalid Safari cookie page size") if page_size < 12 || cursor + page_size > data.size
        parse_safari_page(data[cursor, page_size], jar)
        cursor += page_size
      end
      jar
    rescue error : RequestError
      raise error
    rescue error
      raise RequestError.new("Unable to read Safari cookie file: #{error.message}", cause: error)
    end

    private def parse_safari_page(page : Bytes, jar : CookieJar)
      raise RequestError.new("Invalid Safari cookie page") unless read_u32_le(page, 0) == 256
      cookie_count = read_u32_le(page, 4).to_i
      header_end = 12 + cookie_count * 4
      raise RequestError.new("Invalid Safari cookie page header") if page.size < header_end
      cookie_count.times do |index|
        offset = read_u32_le(page, 8 + index * 4).to_i
        parse_safari_cookie(page, offset, jar)
      end
    end

    private def parse_safari_cookie(page : Bytes, offset : Int32, jar : CookieJar)
      raise RequestError.new("Invalid Safari cookie offset") if offset < 0 || offset + 56 > page.size
      cookie_size = read_u32_le(page, offset).to_i
      raise RequestError.new("Invalid Safari cookie size") if cookie_size < 56 || offset + cookie_size > page.size
      cookie = page[offset, cookie_size]
      flags = read_u32_le(cookie, 8)
      domain = safari_cookie_string(cookie, read_u32_le(cookie, 16).to_i)
      name = safari_cookie_string(cookie, read_u32_le(cookie, 20).to_i)
      path = safari_cookie_string(cookie, read_u32_le(cookie, 24).to_i)
      value = safari_cookie_string(cookie, read_u32_le(cookie, 28).to_i)
      expires_at = safari_expiry(read_f64_le(cookie, 40))
      jar.add(CookieJar::Cookie.new(
        normalize_domain(domain),
        domain.starts_with?('.'),
        normalize_path(path),
        (flags & 1) != 0,
        expires_at,
        name,
        value,
        (flags & 4) != 0,
      ))
    end

    private def safari_cookie_string(cookie : Bytes, offset : Int32) : String
      raise RequestError.new("Invalid Safari cookie string offset") if offset < 0 || offset >= cookie.size
      finish = offset
      while finish < cookie.size && cookie[finish] != 0
        finish += 1
      end
      String.new(cookie[offset...finish])
    end

    private def safari_expiry(value : Float64) : Int64?
      return nil if value <= 0
      (value + 978_307_200).to_i64
    end

    private def read_u32_be(data : Bytes, offset : Int32) : UInt32
      IO::ByteFormat::BigEndian.decode(UInt32, data[offset, 4])
    end

    private def read_u32_le(data : Bytes, offset : Int32) : UInt32
      IO::ByteFormat::LittleEndian.decode(UInt32, data[offset, 4])
    end

    private def read_f64_le(data : Bytes, offset : Int32) : Float64
      IO::ByteFormat::LittleEndian.decode(Float64, data[offset, 8])
    end

    record ChromiumSettings, browser_dir : String, keyring_name : String, supports_profiles : Bool

    private def chromium_settings(browser : String) : ChromiumSettings
      browser_dir = chromium_browser_dir(browser)
      keyring_name = {
        "brave"    => "Brave",
        "chrome"   => "Chrome",
        "chromium" => "Chromium",
        "edge"     => {% if flag?(:darwin) %}"Microsoft Edge"{% else %}"Chromium"{% end %},
        "opera"    => {% if flag?(:darwin) %}"Opera"{% else %}"Chromium"{% end %},
        "vivaldi"  => {% if flag?(:darwin) %}"Vivaldi"{% else %}"Chrome"{% end %},
        "whale"    => "Whale",
      }[browser].not_nil!

      ChromiumSettings.new(browser_dir, keyring_name, browser != "opera")
    end

    private def chromium_browser_dir(browser : String) : String
      {% if flag?(:win32) %}
        local = ENV["LOCALAPPDATA"]? || ""
        roaming = ENV["APPDATA"]? || ""
        {
          "brave"    => File.join(local, "BraveSoftware", "Brave-Browser", "User Data"),
          "chrome"   => File.join(local, "Google", "Chrome", "User Data"),
          "chromium" => File.join(local, "Chromium", "User Data"),
          "edge"     => File.join(local, "Microsoft", "Edge", "User Data"),
          "opera"    => File.join(roaming, "Opera Software", "Opera Stable"),
          "vivaldi"  => File.join(local, "Vivaldi", "User Data"),
          "whale"    => File.join(local, "Naver", "Naver Whale", "User Data"),
        }[browser].not_nil!
      {% elsif flag?(:darwin) %}
        appdata = File.expand_path("~/Library/Application Support")
        {
          "brave"    => File.join(appdata, "BraveSoftware/Brave-Browser"),
          "chrome"   => File.join(appdata, "Google/Chrome"),
          "chromium" => File.join(appdata, "Chromium"),
          "edge"     => File.join(appdata, "Microsoft Edge"),
          "opera"    => File.join(appdata, "com.operasoftware.Opera"),
          "vivaldi"  => File.join(appdata, "Vivaldi"),
          "whale"    => File.join(appdata, "Naver/Whale"),
        }[browser].not_nil!
      {% else %}
        config = ENV["XDG_CONFIG_HOME"]? || File.expand_path("~/.config")
        {
          "brave"    => File.join(config, "BraveSoftware/Brave-Browser"),
          "chrome"   => File.join(config, "google-chrome"),
          "chromium" => File.join(config, "chromium"),
          "edge"     => File.join(config, "microsoft-edge"),
          "opera"    => File.join(config, "opera"),
          "vivaldi"  => File.join(config, "vivaldi"),
          "whale"    => File.join(config, "naver-whale"),
        }[browser].not_nil!
      {% end %}
    end

    private def chromium_search_root(config : ChromiumSettings, profile : String?) : String
      if profile.nil?
        config.browser_dir
      elsif profile_path?(profile)
        profile
      elsif config.supports_profiles
        File.join(config.browser_dir, profile)
      else
        STDERR.puts("ERROR: browser does not support profiles")
        config.browser_dir
      end
    end

    private def chromium_decryption_root(
      config : ChromiumSettings,
      profile : String?,
      search_root : String,
    ) : String
      return config.browser_dir unless profile && profile_path?(profile)
      return search_root if File.exists?(File.join(search_root, "Local State"))
      parent = Path.new(search_root).parent.to_s
      File.exists?(File.join(parent, "Local State")) ? parent : search_root
    end

    private def sqlite_uri(path : String) : String
      "sqlite3:///#{File.expand_path(path).gsub('\\', '/')}"
    end

    private def with_database_copy(source : String, &)
      tmpdir = File.join(Dir.tempdir, "cr-dlp-cookies-#{Random::Secure.hex(6)}")
      Dir.mkdir_p(tmpdir)
      begin
        copy = File.join(tmpdir, "temporary.sqlite")
        FileUtils.cp(source, copy)
        DB.open(sqlite_uri(copy)) do |db|
          yield db
        end
      ensure
        FileUtils.rm_rf(tmpdir)
      end
    rescue error : File::Error
      {% if flag?(:win32) %}
        if error.os_error == 13
          raise RequestError.new(
            "Could not copy Chrome cookie database. See https://github.com/yt-dlp/yt-dlp/issues/7271 for more info"
          )
        end
      {% end %}
      raise RequestError.new("Unable to read browser cookie database: #{error.message}", cause: error)
    end

    private def table_columns(db, table : String) : Array(String)
      columns = [] of String
      db.query("PRAGMA table_info(#{table})") do |rs|
        rs.each do
          rs.read(Int32)
          columns << rs.read(String)
          4.times { rs.read(DB::Any) }
        end
      end
      columns
    end

    private def read_blob(rs) : Bytes
      case value = rs.read(DB::Any)
      when Bytes  then value
      when String then value.to_slice
      else             Bytes.empty
      end
    end

    private def read_blob_or_string(rs) : String
      value = rs.read(DB::Any)
      case value
      when String then value
      when Bytes  then String.new(value)
      else             value.to_s
      end
    end

    private def find_files(root : String, filename : String) : Array(String)
      return [] of String unless Dir.exists?(root)
      files = [] of String
      direct = File.join(root, filename)
      files << direct if File.exists?(direct)
      Dir.glob(File.join(root, "**", filename)) { |path| files << path }
      files.uniq
    end

    private def newest(files : Array(String)) : String?
      files.max_by? { |path| File.info(path).modification_time }
    end

    private def profile_path?(value : String) : Bool
      expanded = File.expand_path(value)
      return true if File.exists?(expanded)
      return true if File.exists?(File.join(expanded, "cookies.sqlite"))
      return true if File.exists?(File.join(expanded, "Cookies"))
      value.includes?(File::SEPARATOR) || value.includes?('/') ||
        !!value.match(/^[A-Za-z]:[\\\/]/)
    end

    private def normalize_domain(domain : String) : String
      domain.strip.downcase.lstrip('.')
    end

    private def normalize_path(path : String) : String
      path.starts_with?('/') ? path : "/"
    end

    class ChromiumCookieDecryptor
      @v10_key : Bytes
      @empty_key : Bytes
      @v11_key : Bytes?
      @windows_gcm_key : Bytes?
      @meta_version : Int32

      def initialize(browser_root : String, browser_keyring : String, keyring : String?, meta_version : Int32)
        @v10_key = macos_v10_key(browser_keyring) || derive_key("peanuts")
        @empty_key = derive_key("")
        @v11_key = linux_v11_key(browser_keyring, keyring)
        @windows_gcm_key = windows_gcm_key(browser_root)
        @meta_version = meta_version
        @browser_root = browser_root
      end

      def decrypt(encrypted_value : Bytes) : String?
        return if encrypted_value.size < 3
        version = String.new(encrypted_value[0, 3])
        ciphertext = encrypted_value[3..]? || return

        case version
        when "v10"
          if key = @windows_gcm_key
            if value = decrypt_aes_gcm(ciphertext, key)
              return value
            end
          end
          decrypt_aes_cbc_multi(ciphertext, {@v10_key, @empty_key})
        when "v11"
          if key = @windows_gcm_key
            if value = decrypt_aes_gcm(ciphertext, key)
              return value
            end
          end
          key = @v11_key
          return unless key
          decrypt_aes_cbc_multi(ciphertext, {key, @empty_key})
        else
          {% if flag?(:win32) %}
            decrypt_windows(encrypted_value)
          {% else %}
            nil
          {% end %}
        end
      rescue CryptoError
        nil
      end

      private def derive_key(password : String) : Bytes
        OpenSSL::PKCS5.pbkdf2_hmac_sha1(
          password,
          "saltysalt",
          {% if flag?(:darwin) %}1003{% else %}1{% end %},
          16,
        )
      end

      private def linux_v11_key(browser_keyring : String, keyring : String?) : Bytes?
        {% if !flag?(:win32) && !flag?(:darwin) %}
          password = linux_keyring_password(browser_keyring, keyring)
          password ? derive_key(password) : nil
        {% else %}
          nil
        {% end %}
      end

      private def linux_keyring_password(browser_keyring : String, keyring : String?) : String?
        {% if !flag?(:win32) && !flag?(:darwin) %}
          case (keyring || "GNOMEKEYRING").upcase
          when "BASICTEXT"
            return ""
          when "GNOMEKEYRING"
            stdout = IO::Memory.new
            status = Process.run(
              "secret-tool",
              ["lookup", "application", "chrome", "xdg:schema", "chrome_libsecret_os_crypt_password_v11"],
              output: stdout,
              error: Process::Redirect::Close,
            )
            return String.new(stdout.to_slice).strip if status.success? && !stdout.to_slice.empty?
          end
        {% end %}
        nil
      end

      private def macos_v10_key(browser_keyring : String) : Bytes?
        {% if flag?(:darwin) %}
          stdout = IO::Memory.new
          status = Process.run(
            "security",
            ["find-generic-password", "-w", "-s", "#{browser_keyring} Safe Storage"],
            output: stdout,
            error: Process::Redirect::Close,
          )
          return unless status.success?
          password = String.new(stdout.to_slice).strip
          password.empty? ? nil : derive_key(password)
        {% else %}
          nil
        {% end %}
      end

      private def windows_gcm_key(browser_root : String) : Bytes?
        {% if flag?(:win32) %}
          local_state = File.join(browser_root, "Local State")
          return unless File.exists?(local_state)
          encrypted_key = JSON.parse(File.read(local_state))
            .as_h["os_crypt"]?.try(&.as_h["encrypted_key"]?).try(&.as_s?)
          return unless encrypted_key
          decoded = Base64.decode(encrypted_key)
          decoded = decoded[5..] if decoded.size > 5 && String.new(decoded[0, 5]) == "DPAPI"
          decrypt_windows_dpapi(decoded)
        {% else %}
          nil
        {% end %}
      rescue JSON::ParseException | Base64::Error | KeyError | TypeCastError
        nil
      end

      private def decrypt_aes_cbc_multi(ciphertext : Bytes, keys : Tuple(Bytes, Bytes) | Tuple(Bytes)) : String?
        keys.each do |key|
          plaintext = AES.unpad_pkcs7(AES.aes_cbc_decrypt_bytes(ciphertext, key, Bytes.new(16, 32_u8)))
          trimmed = @meta_version >= 24 ? strip_hash_prefix(plaintext) : plaintext
          return String.new(trimmed)
        rescue CryptoError | ArgumentError
          # try next key
        end
        nil
      end

      private def decrypt_aes_gcm(payload : Bytes, key : Bytes) : String?
        return if payload.size < 12 + 16
        nonce = payload[0, 12]
        tag = payload[(payload.size - 16), 16]
        encrypted = payload[12, payload.size - 12 - 16]
        plaintext = AES.aes_gcm_decrypt_and_verify(encrypted, key, tag, nonce)
        String.new(strip_hash_prefix(plaintext))
      rescue CryptoError | ArgumentError
        nil
      end

      private def strip_hash_prefix(data : Bytes) : Bytes
        return data if data.size <= 32
        data[32..]
      end

      {% if flag?(:win32) %}
        private def decrypt_windows(encrypted_value : Bytes) : String?
          plaintext = decrypt_windows_dpapi(encrypted_value) || return
          String.new(strip_hash_prefix(plaintext))
        end

        private def decrypt_windows_dpapi(encrypted_value : Bytes) : Bytes?
          input = LibCrypt32::DataBlob.new(
            cb_data: encrypted_value.size.to_u32,
            pb_data: encrypted_value.to_unsafe,
          )
          output = LibCrypt32::DataBlob.new(cb_data: 0_u32, pb_data: Pointer(UInt8).null)
          status = LibCrypt32.crypt_unprotect_data(
            pointerof(input),
            Pointer(Void).null,
            Pointer(LibCrypt32::DataBlob).null,
            Pointer(Void).null,
            Pointer(Void).null,
            0_u32,
            pointerof(output),
          )
          return nil if status == 0
          result = Bytes.new(output.cb_data.to_i) do |index|
            output.pb_data[index]
          end
          LibC.LocalFree(output.pb_data.as(Void*)) unless output.pb_data.null?
          result
        end
      {% end %}
    end
  end
end
