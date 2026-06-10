require "./spec_helper"

private def openssl_encrypt(name : String, data : Bytes, key : Bytes, iv : Bytes? = nil) : Bytes
  cipher = OpenSSL::Cipher.new(name)
  cipher.encrypt
  cipher.padding = false
  cipher.key = key
  cipher.iv = iv if iv
  output = IO::Memory.new
  output.write(cipher.update(data))
  output.write(cipher.final)
  output.to_slice
end

describe CrDlp::AES do
  key = Bytes[0x20, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  iv = key
  secret = "Secret message goes here".to_slice

  it "matches the NIST AES block vectors for every key size" do
    plaintext = "00112233445566778899aabbccddeeff".hexbytes
    {
      "000102030405060708090a0b0c0d0e0f"                                 => "69c4e0d86a7b0430d8cdb78070b4c55a",
      "000102030405060708090a0b0c0d0e0f1011121314151617"                 => "dda97ca4864cdfe06eaf70a0ec0d7191",
      "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" => "8ea2b7ca516745bfeafc49904b496089",
    }.each do |key_hex, encrypted_hex|
      encrypted = CrDlp::AES.encrypt_block(plaintext, key_hex.hexbytes)
      encrypted.hexstring.should eq(encrypted_hex)
      CrDlp::AES.decrypt_block(encrypted, key_hex.hexbytes).should eq(plaintext)
    end
  end

  it "preserves the pinned low-level short-input behavior" do
    message = "message".to_slice
    expanded_key = Bytes.new(16) { |index| index.to_u8 }
    encrypted = CrDlp::AES.aes_encrypt(message, expanded_key)
    CrDlp::AES.aes_decrypt(encrypted, expanded_key).should eq(message)
  end

  it "matches the pinned CBC vectors" do
    encrypted = "97922be50bc318916b79396d26b3b540e627c2962ec87588ab392d5b9e7cf1cd".hexbytes
    CrDlp::AES.aes_cbc_encrypt(secret, key, iv).should eq(encrypted)
    padded = IO::Memory.new
    padded.write(secret[0, 16])
    padded.write(CrDlp::AES.pad_block(secret[16, secret.size - 16], "pkcs7"))
    CrDlp::AES.aes_cbc_decrypt(encrypted, key, iv).should eq(padded.to_slice)
    CrDlp::AES.aes_cbc_decrypt_bytes(encrypted, key, iv).should eq(padded.to_slice)
    CrDlp::AES.unpad_pkcs7(
      CrDlp::AES.aes_cbc_decrypt(encrypted, key, iv),
      validate: true,
    ).should eq(secret)
  end

  it "matches the pinned CTR vectors" do
    encrypted = "03c7ddd48eb3bc1a2a4fdc31122b3841696fd17ab523af08".hexbytes
    CrDlp::AES.aes_ctr_encrypt(secret, key, iv).should eq(encrypted)
    CrDlp::AES.aes_ctr_decrypt(encrypted, key, iv).should eq(secret)
  end

  it "matches the pinned ECB vectors" do
    encrypted = "aa865d81973e02929d1b525b5b4c2f75d326d12868de7b8194ba02aebda6d03a".hexbytes
    CrDlp::AES.aes_ecb_encrypt(secret, key).should eq(encrypted)
    decrypted = CrDlp::AES.aes_ecb_decrypt(encrypted, key)
    CrDlp::AES.unpad_pkcs7(decrypted, validate: true).should eq(secret)
  end

  it "decrypts and authenticates pinned GCM vectors" do
    encrypted = "153959cf35657564909c85265d141d0f2e08b454e42f17bd".hexbytes
    tag = "e82649807249079d7d59577555403a65".hexbytes
    CrDlp::AES.aes_gcm_decrypt_and_verify(encrypted, key, tag, iv[0, 12]).should eq(secret)

    aligned = encrypted[0, 16]
    aligned_tag = "08b19d212698d0ea527190e63bb55dd8".hexbytes
    CrDlp::AES.aes_gcm_decrypt_and_verify(aligned, key, aligned_tag, iv[0, 12]).should eq(secret[0, 16])

    bad_tag = tag.dup
    bad_tag[0] ^= 1
    expect_raises(CrDlp::CryptoError, "Mismatching authentication tag") do
      CrDlp::AES.aes_gcm_decrypt_and_verify(encrypted, key, bad_tag, iv[0, 12])
    end
  end

  it "matches the NIST zero-block GCM vector" do
    zero_key = Bytes.new(16, 0_u8)
    zero_nonce = Bytes.new(12, 0_u8)
    encrypted = "0388dace60b6a392f328c2b971b2fe78".hexbytes
    tag = "ab6e47d42cec13bdf53a67b21257bddf".hexbytes
    CrDlp::AES.aes_gcm_decrypt_and_verify(encrypted, zero_key, tag, zero_nonce).should eq(Bytes.new(16, 0_u8))
  end

  it "handles non-standard GCM nonce and tag lengths" do
    vectors = [
      {
        key:    "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        nonce:  "0001020304050607",
        plain:  "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425",
        cipher: "4854f06841495648e149cf2aa72185292e9343bebd442993f658d3de7fcf859d4fd81130f6",
        tag:    "5144e730f0e6831b1d9ca275",
      },
      {
        key:    "000102030405060708090a0b0c0d0e0f1011121314151617",
        nonce:  "000102030405060708090a0b0c0d0e0f10",
        plain:  "6e6f6e2d7374616e64617264206e6f6e636520766563746f72",
        cipher: "4fdbf2896dc236ea94c399168d74c75142cf03ae155d88a31b",
        tag:    "aa562ae29bce8188b04b46a79b72d9a4",
      },
    ]

    vectors.each do |vector|
      CrDlp::AES.aes_gcm_decrypt_and_verify(
        vector[:cipher].hexbytes,
        vector[:key].hexbytes,
        vector[:tag].hexbytes,
        vector[:nonce].hexbytes,
      ).should eq(vector[:plain].hexbytes)
    end
  end

  it "matches yt-dlp AES password text decryption" do
    password = String.new(key)
    encrypted_128 = Base64.strict_encode(
      Bytes[0x20, 0x15, 0, 0, 0, 0, 0, 0] +
      "171593ab8d8056cd56e009cd6fc2a5d86b734d0de2374eae".hexbytes,
    )
    encrypted_256 = Base64.strict_encode(
      Bytes[0x20, 0x15, 0, 0, 0, 0, 0, 0] +
      "0be6a4d97a0eb8b9d0d4695f851d99985fe580e72ebfa583".hexbytes,
    )

    CrDlp::AES.aes_decrypt_text(encrypted_128, password, 16).should eq(secret)
    CrDlp::AES.aes_decrypt_text(encrypted_256, password, 32).should eq(secret)
  end

  it "matches the pinned key schedule" do
    key = "4f6bdaa39e2f8cb07f5e722d9edef314".hexbytes
    expected = (
      "4f6bdaa39e2f8cb07f5e722d9edef314536620a8cd49ac18b217de352cc92d21" +
      "8cbeddd941f771c1f3e0aff4df2982d52dadde476c5aaf869fba0072409382a7" +
      "f9be824e95e42dc80a5e2dba4acdaf1d54c72698c1230b50cb7d26ea81b089f7" +
      "93604e94524345c4993e632e188eead9cae77b3998a43efd019a5dd31914b70a" +
      "b04e1ced28ea221029707fc33064c8c9e8a6c1e9c04ce3f9e93c9c3ad95854f3" +
      "b486ccdc74ca2f259df6b31f44aee7ec"
    ).hexbytes
    CrDlp::AES.key_expansion(key).should eq(expected)
  end

  it "implements all pinned block padding modes" do
    block = Bytes[0x21, 0xa0, 0x43, 0xff]
    CrDlp::AES.pad_block(block, "pkcs7").should eq(
      Bytes[0x21, 0xa0, 0x43, 0xff, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12]
    )
    CrDlp::AES.pad_block(block, "iso7816").should eq(
      Bytes[0x21, 0xa0, 0x43, 0xff, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    )
    CrDlp::AES.pad_block(block, "whitespace").should eq(
      Bytes[0x21, 0xa0, 0x43, 0xff, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20]
    )
    CrDlp::AES.pad_block(block, "zero").should eq(
      Bytes[0x21, 0xa0, 0x43, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    )

    complete = Bytes.new(16) { |index| index.to_u8 }
    {"pkcs7", "iso7816", "whitespace", "zero"}.each do |mode|
      CrDlp::AES.pad_block(complete, mode).should eq(complete)
    end
  end

  it "validates keys, IVs, padding, and unsupported modes" do
    expect_raises(CrDlp::CryptoError, "AES key must") do
      CrDlp::AES.key_expansion(Bytes.new(15))
    end
    expect_raises(CrDlp::CryptoError, "AES IV must") do
      CrDlp::AES.aes_ctr_encrypt(secret, key, Bytes.new(12))
    end
    expect_raises(CrDlp::CryptoError, "Invalid PKCS#7 padding") do
      CrDlp::AES.unpad_pkcs7(Bytes[1, 2, 3, 2], validate: true)
    end
    CrDlp::AES.unpad_pkcs7(Bytes[1, 2, 0]).should be_empty
    expect_raises(CrDlp::CryptoError, "not implemented") do
      CrDlp::AES.pad_block(Bytes[1], "unknown")
    end
    expect_raises(CrDlp::CryptoError, "tag must be") do
      CrDlp::AES.aes_gcm_decrypt_and_verify(Bytes.empty, key, Bytes.empty, iv[0, 12])
    end
  end

  it "agrees with OpenSSL for ECB, CBC, and CTR across all key sizes" do
    vector_iv = Bytes.new(16) { |index| (255 - index * 9).to_u8 }

    {16, 24, 32}.each do |key_size|
      vector_key = Bytes.new(key_size) { |index| ((index * 17 + key_size) & 0xff).to_u8 }
      bits = key_size * 8

      {16, 32, 64, 128}.each do |size|
        plaintext = Bytes.new(size) { |index| ((index * 29 + size + key_size) & 0xff).to_u8 }
        pure_ecb = CrDlp::AES.aes_ecb_encrypt(plaintext, vector_key)
        pure_ecb.should eq(openssl_encrypt("aes-#{bits}-ecb", plaintext, vector_key))
        CrDlp::AES.aes_ecb_decrypt(pure_ecb, vector_key).should eq(plaintext)

        pure_cbc = CrDlp::AES.aes_cbc_encrypt(plaintext, vector_key, vector_iv)
        pure_cbc.should eq(openssl_encrypt("aes-#{bits}-cbc", plaintext, vector_key, vector_iv))
        CrDlp::AES.aes_cbc_decrypt(pure_cbc, vector_key, vector_iv).should eq(plaintext)
      end

      {1, 15, 16, 17, 31, 32, 63, 65, 127}.each do |size|
        plaintext = Bytes.new(size) { |index| ((index * 31 + size + key_size) & 0xff).to_u8 }
        pure_ctr = CrDlp::AES.aes_ctr_encrypt(plaintext, vector_key, vector_iv)
        pure_ctr.should eq(openssl_encrypt("aes-#{bits}-ctr", plaintext, vector_key, vector_iv))
        CrDlp::AES.aes_ctr_decrypt(pure_ctr, vector_key, vector_iv).should eq(plaintext)
      end
    end
  end
end
