require "./spec_helper"
require "base64"
require "big"

TEST_RSA_N = BigInt.new(
  "621048304397ccf6ce83d0a0cdb2ee760ac52b69ed5fbe37f17ee2e5e9a21c95bc7c3ef32fad4da9caf4921fcf3a84ab51fbc6ca0fce64893e8fdc12d7e3e6eb0b9a303360f0123339d5c9a905569a0fc7d2a32ca236e24d6d436e63d29414646f1370343da8f31f0e036fa3072973f0e42c7296e635d8ab2e7f9371100c06fb",
  16,
)
TEST_RSA_E = BigInt.new(65537)
TEST_RSA_D = BigInt.new(
  "2f73d38acf5a888b3199a57dfaabc82a84c1ae655ec142c9cd696a207932c2044f260c4c1f590c48ca7618b39dd2a25a489cbe300effffb44dfacd32ad179228b6d5d06dbcce145c1b2559c2ad0b103e1d02eb9bd106dfc78d8512f3c76875b76495122c60a564d7fa46d8cab86b1aef2ea469904eb8a2b37642045fe1f93591",
  16,
)

private def current_platform : String
  {% if flag?(:win32) %}
    "windows"
  {% elsif flag?(:darwin) %}
    "macos"
  {% else %}
    "linux"
  {% end %}
end

private def current_arch : String
  {% if flag?(:x86_64) %}
    "x86_64"
  {% elsif flag?(:aarch64) %}
    "aarch64"
  {% else %}
    "unknown"
  {% end %}
end

private def update_manifest(path : String, artifact : String, sha256 : String, version = "9.9.9")
  File.write(path, {
    "version"   => version,
    "artifacts" => [
      {
        "name"     => "cr-dlp-test",
        "platform" => current_platform,
        "arch"     => current_arch,
        "url"      => File.basename(artifact),
        "sha256"   => sha256,
      },
    ],
  }.to_json)
end

private def sign_manifest(path : String)
  document = File.read(path)
  key_length = CrDlp::RsaSha256Verifier.byte_length(TEST_RSA_N)
  hash = Digest::SHA256.digest(document)
  digest_info = CrDlp::RsaSha256Verifier::DIGEST_INFO_SHA256_PREFIX + hash
  padding = key_length - digest_info.size - 3
  encoded = Bytes.new(key_length, 0_u8)
  encoded[0] = 0_u8
  encoded[1] = 1_u8
  padding.times { |index| encoded[index + 2] = 0xff_u8 }
  encoded[padding + 2] = 0_u8
  encoded[(padding + 3)..].copy_from(digest_info)
  signature = CrDlp::RsaSha256Verifier.mod_pow(
    CrDlp::RsaSha256Verifier.bytes_to_bigint(encoded),
    TEST_RSA_D,
    TEST_RSA_N,
  )
  File.write(
    "#{path}.sig",
    Base64.strict_encode(CrDlp::RsaSha256Verifier.bigint_to_bytes(signature, key_length)),
  )
end

describe CrDlp::Updater do
  it "downloads, verifies, and transactionally replaces the target executable" do
    directory = File.join(Dir.tempdir, "cr-dlp-update-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      executable = File.join(directory, "cr-dlp-test")
      artifact = File.join(directory, "artifact.bin")
      manifest = File.join(directory, "manifest.json")
      File.write(executable, "old")
      File.write(artifact, "new")
      update_manifest(manifest, artifact, Digest::SHA256.hexdigest("new"))
      output = IO::Memory.new

      result = CrDlp::Updater.new(current_executable: executable, output: output).run(manifest)

      result.updated.should be_true
      result.version.should eq("9.9.9")
      File.read(executable).should eq("new")
      File.exists?("#{executable}.old").should be_false
      output.to_s.should contain("Updated cr-dlp")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "rejects hash mismatches without replacing the executable" do
    directory = File.join(Dir.tempdir, "cr-dlp-update-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      executable = File.join(directory, "cr-dlp-test")
      artifact = File.join(directory, "artifact.bin")
      manifest = File.join(directory, "manifest.json")
      File.write(executable, "old")
      File.write(artifact, "new")
      update_manifest(manifest, artifact, "0" * 64)

      expect_raises(CrDlp::UpdateError, /hash mismatch/) do
        CrDlp::Updater.new(current_executable: executable, output: IO::Memory.new).run(manifest)
      end
      File.read(executable).should eq("old")
      Dir.children(directory).any?(&.includes?(".update-")).should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "reports preview builds without a configured manifest as a no-op" do
    output = IO::Memory.new
    result = CrDlp::Updater.new(current_executable: "unused", output: output).run("stable")

    result.updated.should be_false
    output.to_s.should contain("No cr-dlp update manifest configured")
  end

  it "verifies signed channel manifests before replacing the executable" do
    directory = File.join(Dir.tempdir, "cr-dlp-update-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      executable = File.join(directory, "cr-dlp-test")
      artifact = File.join(directory, "artifact.bin")
      manifest = File.join(directory, "manifest.json")
      File.write(executable, "old")
      File.write(artifact, "signed")
      update_manifest(manifest, artifact, Digest::SHA256.hexdigest("signed"))
      sign_manifest(manifest)
      key = CrDlp::RsaPublicKey.new(TEST_RSA_N, TEST_RSA_E)

      result = CrDlp::Updater.new(
        current_executable: executable,
        output: IO::Memory.new,
        trusted_keys: [key],
      ).run(manifest)

      result.updated.should be_true
      File.read(executable).should eq("signed")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "resolves signed stable channel manifests from the channel environment" do
    directory = File.join(Dir.tempdir, "cr-dlp-update-#{Random::Secure.hex(6)}")
    previous = ENV["CR_DLP_UPDATE_STABLE_MANIFEST"]?
    Dir.mkdir(directory)
    begin
      executable = File.join(directory, "cr-dlp-test")
      artifact = File.join(directory, "artifact.bin")
      manifest = File.join(directory, "manifest.json")
      File.write(executable, "old")
      File.write(artifact, "channel")
      update_manifest(manifest, artifact, Digest::SHA256.hexdigest("channel"))
      sign_manifest(manifest)
      ENV["CR_DLP_UPDATE_STABLE_MANIFEST"] = manifest
      key = CrDlp::RsaPublicKey.new(TEST_RSA_N, TEST_RSA_E)

      result = CrDlp::Updater.new(
        current_executable: executable,
        output: IO::Memory.new,
        trusted_keys: [key],
      ).run("stable")

      result.updated.should be_true
      File.read(executable).should eq("channel")
    ensure
      if previous
        ENV["CR_DLP_UPDATE_STABLE_MANIFEST"] = previous
      else
        ENV.delete("CR_DLP_UPDATE_STABLE_MANIFEST")
      end
      FileUtils.rm_rf(directory)
    end
  end

  it "rejects tampered signed manifests" do
    directory = File.join(Dir.tempdir, "cr-dlp-update-#{Random::Secure.hex(6)}")
    Dir.mkdir(directory)
    begin
      executable = File.join(directory, "cr-dlp-test")
      artifact = File.join(directory, "artifact.bin")
      manifest = File.join(directory, "manifest.json")
      File.write(executable, "old")
      File.write(artifact, "signed")
      update_manifest(manifest, artifact, Digest::SHA256.hexdigest("signed"))
      sign_manifest(manifest)
      update_manifest(manifest, artifact, Digest::SHA256.hexdigest("signed"), version: "9.9.10")
      key = CrDlp::RsaPublicKey.new(TEST_RSA_N, TEST_RSA_E)

      expect_raises(CrDlp::UpdateError, /signature verification failed/) do
        CrDlp::Updater.new(
          current_executable: executable,
          output: IO::Memory.new,
          trusted_keys: [key],
        ).run(manifest)
      end
      File.read(executable).should eq("old")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
