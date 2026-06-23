require "base64"
require "big"
require "digest/sha256"
require "file_utils"
require "random/secure"

module CrDlp
  class UpdateTarget
    getter channel : String
    getter tag : String
    getter manifest_url : String?
    getter explicit : Bool

    def initialize(
      @channel : String,
      @tag : String,
      @manifest_url : String? = nil,
      @explicit = false,
    )
    end

    def self.parse(value : String?) : self
      return new("stable", "latest") unless value && !value.empty?
      if manifest_source?(value)
        return new("custom", "latest", value, explicit: true)
      end

      channel, separator, tag = value.partition('@')
      channel = "stable" if channel.empty?
      tag = "latest" if separator.empty? || tag.empty?
      new(channel, tag, explicit: true)
    end

    def display : String
      manifest_url || "#{channel}@#{tag}"
    end

    private def self.manifest_source?(value : String) : Bool
      value.ends_with?(".json") ||
        value.starts_with?("http://") ||
        value.starts_with?("https://") ||
        value.starts_with?("file://") ||
        File.exists?(value)
    end
  end

  class UpdateArtifact
    include JSON::Serializable

    getter name : String?
    getter platform : String
    getter arch : String
    getter url : String
    getter sha256 : String
    getter size : Int64?
  end

  class UpdateManifest
    include JSON::Serializable

    getter version : String
    getter channel : String?
    getter tag : String?
    getter notes : String?
    getter artifacts : Array(UpdateArtifact)
  end

  record UpdateResult,
    updated : Bool,
    version : String?,
    message : String

  record RsaPublicKey, modulus : BigInt, exponent : BigInt do
    def self.parse(value : String) : self
      algorithm, modulus, exponent = value.split(':', 3)
      unless algorithm.downcase.in?("rsa-sha256", "rsa-pkcs1-sha256")
        raise UpdateError.new("Unsupported update public key algorithm #{algorithm.inspect}")
      end
      new(BigInt.new(modulus, 16), exponent.starts_with?("0x") ? BigInt.new(exponent[2..], 16) : BigInt.new(exponent))
    rescue error : ArgumentError | IndexError
      raise UpdateError.new("Invalid update public key", cause: error)
    end
  end

  module RsaSha256Verifier
    extend self

    DIGEST_INFO_SHA256_PREFIX = Bytes[
      0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
      0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
      0x00, 0x04, 0x20,
    ]

    def verify(document : String, signature_base64 : String, keys : Array(RsaPublicKey)) : Bool
      signature = Base64.decode(signature_base64.strip)
      keys.any? { |key| verify_key(document, signature, key) }
    rescue Base64::Error
      false
    end

    def verify_key(document : String, signature : Bytes, key : RsaPublicKey) : Bool
      key_length = byte_length(key.modulus)
      return false unless signature.size == key_length
      decoded = bigint_to_bytes(
        mod_pow(bytes_to_bigint(signature), key.exponent, key.modulus),
        key_length,
      )
      return false unless decoded[0]? == 0_u8 && decoded[1]? == 1_u8
      index = 2
      while decoded[index]? == 0xff_u8
        index += 1
      end
      return false if index < 10 || decoded[index]? != 0_u8
      expected = DIGEST_INFO_SHA256_PREFIX + Digest::SHA256.digest(document)
      decoded[(index + 1)..] == expected
    end

    def mod_pow(base : BigInt, exponent : BigInt, modulus : BigInt) : BigInt
      result = BigInt.new(1)
      current = base % modulus
      power = exponent
      zero = BigInt.new(0)
      two = BigInt.new(2)
      while power > zero
        result = (result * current) % modulus if (power % two) == 1
        power = power // two
        current = (current * current) % modulus
      end
      result
    end

    def bytes_to_bigint(bytes : Bytes) : BigInt
      hex = bytes.hexstring
      BigInt.new(hex.empty? ? "0" : hex, 16)
    end

    def bigint_to_bytes(value : BigInt, length : Int32) : Bytes
      hex = value.to_s(16)
      hex = "0#{hex}" if hex.size.odd?
      bytes = hex.hexbytes
      raise UpdateError.new("RSA value is too large") if bytes.size > length
      Bytes.new(length, 0_u8).tap do |result|
        result[(length - bytes.size), bytes.size].copy_from(bytes)
      end
    end

    def byte_length(value : BigInt) : Int32
      hex = value.to_s(16)
      (hex.size + 1) // 2
    end
  end

  class Updater
    DEFAULT_MANIFEST_ENV          = "CR_DLP_UPDATE_MANIFEST"
    DEFAULT_PUBLIC_KEY_ENV        = "CR_DLP_UPDATE_PUBLIC_KEY"
    DEFAULT_REQUIRE_SIGNATURE_ENV = "CR_DLP_UPDATE_REQUIRE_SIGNATURE"

    def initialize(
      @request_director : Networking::RequestDirector = default_request_director,
      @current_executable : String = current_executable,
      @output : IO = STDOUT,
      @error : IO = STDERR,
      @trusted_keys : Array(RsaPublicKey) = update_public_keys,
    )
    end

    def run(spec : String?) : UpdateResult
      target = UpdateTarget.parse(spec)
      manifest_source = target.manifest_url || channel_manifest_source(target)
      unless manifest_source
        message = "No cr-dlp update manifest configured for #{target.display}"
        @output.puts("[update] #{message}")
        @output.puts("[update] Set #{DEFAULT_MANIFEST_ENV}, a channel manifest env var, or pass --update-to MANIFEST.json")
        return UpdateResult.new(false, nil, message)
      end

      manifest_url = manifest_source
      manifest_document = read_source(manifest_url)
      verify_manifest_signature(manifest_document, manifest_url, target)
      manifest = parse_manifest(manifest_document)
      artifact = select_artifact(manifest)
      if manifest.version == VERSION && !target.explicit
        message = "cr-dlp is up to date (#{VERSION})"
        @output.puts("[update] #{message}")
        return UpdateResult.new(false, manifest.version, message)
      end

      artifact_url = resolve_url(manifest_url, artifact.url)
      temporary = download_artifact(artifact_url, artifact.sha256)
      install_artifact(temporary, @current_executable)
      message = "Updated cr-dlp #{VERSION} -> #{manifest.version}"
      @output.puts("[update] #{message}")
      UpdateResult.new(true, manifest.version, message)
    rescue error : UpdateError
      raise error
    rescue error
      raise UpdateError.new("Unable to update cr-dlp: #{error.message}", cause: error)
    end

    private def parse_manifest(document : String) : UpdateManifest
      UpdateManifest.from_json(document)
    rescue error : JSON::ParseException
      raise UpdateError.new("Invalid update manifest: #{error.message}", cause: error)
    end

    private def verify_manifest_signature(document : String, source : String, target : UpdateTarget)
      signature_required = require_signature?(target)
      return unless signature_required || !@trusted_keys.empty?
      raise UpdateError.new("No trusted update public key configured") if @trusted_keys.empty?

      signature = read_source("#{source}.sig").strip
      unless RsaSha256Verifier.verify(document, signature, @trusted_keys)
        raise UpdateError.new("Update manifest signature verification failed")
      end
    rescue error : UpdateError
      raise error
    rescue error
      raise UpdateError.new("Unable to verify update manifest signature: #{error.message}", cause: error)
    end

    private def select_artifact(manifest : UpdateManifest) : UpdateArtifact
      manifest.artifacts.find do |artifact|
        artifact.platform.downcase == platform &&
          artifact.arch.downcase == arch
      end || raise UpdateError.new("Update manifest has no artifact for #{platform}/#{arch}")
    end

    private def read_source(source : String) : String
      case scheme(source)
      when "http", "https"
        response = @request_director.send(Networking::Request.new(source))
        raise HttpError.new(response.status, response.url) unless response.success?
        response.text
      when "file"
        File.read(file_uri_path(source))
      else
        File.read(source)
      end
    end

    private def channel_manifest_source(target : UpdateTarget) : String?
      ENV["CR_DLP_UPDATE_#{target.channel.upcase}_MANIFEST"]? ||
        ENV[DEFAULT_MANIFEST_ENV]?
    end

    private def require_signature?(target : UpdateTarget) : Bool
      return true if ENV[DEFAULT_REQUIRE_SIGNATURE_ENV]?.try(&.downcase).in?("1", "true", "yes")
      !target.manifest_url && !@trusted_keys.empty?
    end

    private def download_artifact(source : String, expected_sha256 : String) : String
      temporary = "#{@current_executable}.update-#{Random::Secure.hex(6)}"
      File.delete?(temporary)
      case scheme(source)
      when "http", "https"
        File.open(temporary, "wb") do |output|
          response = @request_director.download(Networking::Request.new(source), output)
          raise HttpError.new(response.status, response.url) unless response.success?
        end
      when "file"
        FileUtils.cp(file_uri_path(source), temporary)
      else
        FileUtils.cp(source, temporary)
      end

      actual_sha256 = Digest::SHA256.hexdigest(File.read(temporary))
      unless actual_sha256.downcase == expected_sha256.downcase
        File.delete?(temporary)
        raise UpdateError.new(
          "Downloaded update hash mismatch: expected #{expected_sha256}, got #{actual_sha256}"
        )
      end
      temporary
    rescue error : UpdateError
      raise error
    rescue error
      File.delete?(temporary) if temporary
      raise UpdateError.new("Unable to download update artifact: #{error.message}", cause: error)
    end

    private def install_artifact(temporary : String, executable : String)
      backup = "#{executable}.old"
      File.delete?(backup)
      File.rename(executable, backup)
      begin
        File.rename(temporary, executable)
        File.chmod(executable, 0o755) unless windows?
        File.delete?(backup)
      rescue error
        File.rename(backup, executable) if File.exists?(backup) && !File.exists?(executable)
        raise error
      end
    rescue error
      File.delete?(temporary) if File.exists?(temporary)
      raise UpdateError.new("Unable to replace executable: #{error.message}", cause: error)
    end

    private def resolve_url(base : String, reference : String) : String
      return reference if scheme(reference)
      if scheme(base).in?("http", "https", "file")
        URI.parse(base).resolve(reference).to_s
      else
        File.expand_path(reference, Path.new(base).parent.to_s)
      end
    rescue URI::Error
      reference
    end

    private def scheme(source : String) : String?
      URI.parse(source).scheme.presence
    rescue URI::Error
      nil
    end

    private def file_uri_path(source : String) : String
      path = URI.parse(source).path
      {% if flag?(:win32) %}
        path = path.lchop('/') if path.matches?(/\A\/[A-Za-z]:/)
      {% end %}
      path
    rescue URI::Error
      source
    end

    private def current_executable : String
      Process.executable_path || File.expand_path(PROGRAM_NAME)
    end

    private def default_request_director : Networking::RequestDirector
      Networking::RequestDirector.new([
        Networking::CrystalHttpHandler.new,
      ] of Networking::RequestHandler)
    end

    private def update_public_keys : Array(RsaPublicKey)
      key = ENV[DEFAULT_PUBLIC_KEY_ENV]?
      key ? [RsaPublicKey.parse(key)] : [] of RsaPublicKey
    end

    private def platform : String
      {% if flag?(:win32) %}
        "windows"
      {% elsif flag?(:darwin) %}
        "macos"
      {% else %}
        "linux"
      {% end %}
    end

    private def arch : String
      {% if flag?(:x86_64) %}
        "x86_64"
      {% elsif flag?(:aarch64) %}
        "aarch64"
      {% else %}
        "unknown"
      {% end %}
    end

    private def windows? : Bool
      {{ flag?(:win32) }}
    end
  end
end
