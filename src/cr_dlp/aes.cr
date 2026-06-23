require "base64"
require "openssl"

module CrDlp
  # Pure Crystal AES helpers compatible with the pinned yt-dlp implementation.
  module AES
    extend self

    BLOCK_SIZE = 16

    RCON = Bytes[
      0x8d, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40,
      0x80, 0x1b, 0x36,
    ]

    SBOX = Bytes[
      0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
      0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
      0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
      0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
      0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
      0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
      0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
      0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
      0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
      0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
      0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
      0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
      0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
      0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
      0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
      0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]

    SBOX_INV = Bytes[
      0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
      0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
      0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
      0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
      0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
      0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
      0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
      0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
      0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
      0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
      0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
      0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
      0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
      0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
      0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
      0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
    ]

    def pkcs7_padding(data : Bytes) : Bytes
      padding_size = BLOCK_SIZE - data.size % BLOCK_SIZE
      append(data, Bytes.new(padding_size, padding_size.to_u8))
    end

    def unpad_pkcs7(data : Bytes, *, validate = false) : Bytes
      return Bytes.empty if data.empty?
      padding_size = data[-1].to_i
      if validate
        unless 1 <= padding_size <= BLOCK_SIZE && padding_size <= data.size
          raise CryptoError.new("Invalid PKCS#7 padding")
        end
        padding_size.times do |offset|
          raise CryptoError.new("Invalid PKCS#7 padding") unless data[data.size - 1 - offset] == padding_size
        end
      end
      keep = data.size - padding_size
      return Bytes.empty if padding_size == 0 || keep <= 0
      copy(data[0, keep])
    end

    def pad_block(block : Bytes, padding_mode : String) : Bytes
      padding_size = BLOCK_SIZE - block.size
      raise CryptoError.new("Block size exceeded") if padding_size < 0

      padding_byte = case padding_mode
                     when "pkcs7"      then padding_size.to_u8
                     when "iso7816"    then 0_u8
                     when "whitespace" then 0x20_u8
                     when "zero"       then 0_u8
                     else
                       raise CryptoError.new("Padding mode #{padding_mode} is not implemented")
                     end
      return copy(block) if padding_size == 0

      output = Bytes.new(BLOCK_SIZE, padding_byte)
      output[0, block.size].copy_from(block)
      output[block.size] = 0x80_u8 if padding_mode == "iso7816"
      output
    end

    def key_expansion(key : Bytes) : Bytes
      validate_key(key)
      expanded = key.to_a
      key_size = key.size
      target_size = (key_size // 4 + 7) * BLOCK_SIZE
      rcon_iteration = 1

      while expanded.size < target_size
        temp = expanded[-4, 4]
        temp = key_schedule_core(temp, rcon_iteration)
        rcon_iteration += 1
        append_word(expanded, temp, expanded.size - key_size)

        3.times do
          temp = expanded[-4, 4]
          append_word(expanded, temp, expanded.size - key_size)
        end

        if key_size == 32
          temp = expanded[-4, 4].map { |byte| SBOX[byte] }
          append_word(expanded, temp, expanded.size - key_size)
        end

        remaining_words = key_size == 32 ? 3 : key_size == 24 ? 2 : 0
        remaining_words.times do
          temp = expanded[-4, 4]
          append_word(expanded, temp, expanded.size - key_size)
        end
      end

      to_bytes(expanded[0, target_size])
    end

    def aes_encrypt(data : Bytes, expanded_key : Bytes) : Bytes
      rounds = expanded_key.size // BLOCK_SIZE - 1
      return xor(data, expanded_key) if rounds <= 0
      require_block(data)

      state = xor(data[0, BLOCK_SIZE], expanded_key[0, BLOCK_SIZE])
      1.upto(rounds) do |round|
        state = substitute(state, SBOX)
        state = shift_rows(state)
        state = mix_columns(state, false) unless round == rounds
        state = xor(state, expanded_key[round * BLOCK_SIZE, BLOCK_SIZE])
      end
      state
    end

    def aes_decrypt(data : Bytes, expanded_key : Bytes) : Bytes
      rounds = expanded_key.size // BLOCK_SIZE - 1
      return xor(data, expanded_key) if rounds <= 0
      require_block(data)

      state = copy(data[0, BLOCK_SIZE])
      rounds.downto(1) do |round|
        state = xor(state, expanded_key[round * BLOCK_SIZE, BLOCK_SIZE])
        state = mix_columns(state, true) unless round == rounds
        state = shift_rows_inverse(state)
        state = substitute(state, SBOX_INV)
      end
      xor(state, expanded_key[0, BLOCK_SIZE])
    end

    def encrypt_block(data : Bytes, key : Bytes) : Bytes
      aes_encrypt(data, key_expansion(key))
    end

    def decrypt_block(data : Bytes, key : Bytes) : Bytes
      aes_decrypt(data, key_expansion(key))
    end

    def aes_ecb_encrypt(data : Bytes, key : Bytes, iv : Bytes? = nil) : Bytes
      expanded_key = key_expansion(key)
      transform_blocks(data) do |block|
        aes_encrypt(pkcs7_padding(block)[0, BLOCK_SIZE], expanded_key)
      end
    end

    def aes_ecb_decrypt(data : Bytes, key : Bytes, iv : Bytes? = nil) : Bytes
      expanded_key = key_expansion(key)
      transform_blocks(data, trim_to_input: true) do |block|
        aes_decrypt(zero_pad(block), expanded_key)
      end
    end

    def aes_ctr_encrypt(data : Bytes, key : Bytes, iv : Bytes) : Bytes
      validate_iv(iv)
      expanded_key = key_expansion(key)
      counter = copy(iv)
      output = Bytes.new(data.size)

      each_block(data) do |block, offset|
        encrypted_counter = aes_encrypt(counter, expanded_key)
        block.size.times { |index| output[offset + index] = block[index] ^ encrypted_counter[index] }
        counter = increment(counter)
      end
      output
    end

    def aes_ctr_decrypt(data : Bytes, key : Bytes, iv : Bytes) : Bytes
      aes_ctr_encrypt(data, key, iv)
    end

    def aes_cbc_encrypt(
      data : Bytes,
      key : Bytes,
      iv : Bytes,
      *,
      padding_mode = "pkcs7",
    ) : Bytes
      validate_iv(iv)
      expanded_key = key_expansion(key)
      previous = copy(iv)
      output = IO::Memory.new

      each_block(data) do |block, _offset|
        padded = pad_block(block, padding_mode)
        encrypted = aes_encrypt(xor(padded, previous), expanded_key)
        output.write(encrypted)
        previous = encrypted
      end
      output.to_slice
    end

    def aes_cbc_decrypt(data : Bytes, key : Bytes, iv : Bytes) : Bytes
      validate_iv(iv)
      expanded_key = key_expansion(key)
      previous = copy(iv)
      output = Bytes.new(data.size)

      each_block(data) do |block, offset|
        padded = zero_pad(block)
        decrypted = xor(aes_decrypt(padded, expanded_key), previous)
        block.size.times { |index| output[offset + index] = decrypted[index] }
        previous = padded
      end
      output
    end

    def aes_cbc_decrypt_bytes(data : Bytes, key : Bytes, iv : Bytes) : Bytes
      validate_key(key)
      validate_iv(iv)
      unless data.size % BLOCK_SIZE == 0
        raise CryptoError.new("AES-CBC ciphertext must be block aligned")
      end

      cipher = OpenSSL::Cipher.new("aes-#{key.size * 8}-cbc")
      cipher.decrypt
      cipher.padding = false
      cipher.key = key
      cipher.iv = iv
      output = IO::Memory.new
      output.write(cipher.update(data))
      output.write(cipher.final)
      output.to_slice
    rescue OpenSSL::Cipher::Error
      aes_cbc_decrypt(data, key, iv)
    end

    def aes_gcm_decrypt_and_verify(
      data : Bytes,
      key : Bytes,
      tag : Bytes,
      nonce : Bytes,
    ) : Bytes
      unless 1 <= tag.size <= BLOCK_SIZE
        raise CryptoError.new("AES-GCM tag must be between 1 and 16 bytes")
      end
      hash_subkey = encrypt_block(Bytes.new(BLOCK_SIZE, 0_u8), key)
      j0 = if nonce.size == 12
             append(nonce, Bytes[0, 0, 0, 1])
           else
             padding = (BLOCK_SIZE - nonce.size % BLOCK_SIZE) % BLOCK_SIZE + 8
             ghash_input = append(nonce, Bytes.new(padding, 0_u8), uint64_bytes(nonce.size.to_u64 * 8))
             ghash(hash_subkey, ghash_input)
           end

      decrypted = aes_ctr_decrypt(data, key, increment(j0))
      padding = (BLOCK_SIZE - data.size % BLOCK_SIZE) % BLOCK_SIZE
      authentication_input = append(
        data,
        Bytes.new(padding, 0_u8),
        Bytes.new(8, 0_u8),
        uint64_bytes(data.size.to_u64 * 8),
      )
      expected_tag = aes_ctr_encrypt(ghash(hash_subkey, authentication_input), key, j0)
      unless secure_compare(tag, expected_tag[0, tag.size])
        raise CryptoError.new("Mismatching authentication tag")
      end
      decrypted
    end

    def aes_gcm_encrypt_and_tag(
      data : Bytes,
      key : Bytes,
      nonce : Bytes,
      tag_size = BLOCK_SIZE,
    ) : Tuple(Bytes, Bytes)
      unless 1 <= tag_size <= BLOCK_SIZE
        raise CryptoError.new("AES-GCM tag must be between 1 and 16 bytes")
      end
      hash_subkey = encrypt_block(Bytes.new(BLOCK_SIZE, 0_u8), key)
      j0 = if nonce.size == 12
             append(nonce, Bytes[0, 0, 0, 1])
           else
             padding = (BLOCK_SIZE - nonce.size % BLOCK_SIZE) % BLOCK_SIZE + 8
             ghash_input = append(nonce, Bytes.new(padding, 0_u8), uint64_bytes(nonce.size.to_u64 * 8))
             ghash(hash_subkey, ghash_input)
           end

      encrypted = aes_ctr_encrypt(data, key, increment(j0))
      padding = (BLOCK_SIZE - encrypted.size % BLOCK_SIZE) % BLOCK_SIZE
      authentication_input = append(
        encrypted,
        Bytes.new(padding, 0_u8),
        Bytes.new(8, 0_u8),
        uint64_bytes(encrypted.size.to_u64 * 8),
      )
      tag = aes_ctr_encrypt(ghash(hash_subkey, authentication_input), key, j0)[0, tag_size]
      {encrypted, tag}
    end

    def aes_decrypt_text(data : String, password : String, key_size : Int32) : Bytes
      validate_key_size(key_size)
      decoded = Base64.decode(data)
      raise CryptoError.new("Encrypted text is missing its nonce") if decoded.size < 8

      password_bytes = password.to_slice
      initial_key = Bytes.new(key_size, 0_u8)
      copy_size = Math.min(password_bytes.size, key_size)
      initial_key[0, copy_size].copy_from(password_bytes[0, copy_size])
      encrypted_key = encrypt_block(initial_key[0, BLOCK_SIZE], initial_key)
      key = Bytes.new(key_size) { |index| encrypted_key[index % BLOCK_SIZE] }
      nonce = Bytes.new(BLOCK_SIZE, 0_u8)
      nonce[0, 8].copy_from(decoded[0, 8])
      aes_ctr_decrypt(decoded[8, decoded.size - 8], key, nonce)
    rescue error : Base64::Error
      raise CryptoError.new("Invalid base64 encrypted text", cause: error)
    end

    private def validate_key(key : Bytes)
      validate_key_size(key.size)
    end

    private def validate_key_size(size : Int32)
      return if size.in?({16, 24, 32})
      raise CryptoError.new("AES key must be 16, 24, or 32 bytes")
    end

    private def validate_iv(iv : Bytes)
      raise CryptoError.new("AES IV must be 16 bytes") unless iv.size == BLOCK_SIZE
    end

    private def require_block(data : Bytes)
      raise CryptoError.new("AES block must be at least 16 bytes") if data.size < BLOCK_SIZE
    end

    private def key_schedule_core(word : Array(UInt8), iteration : Int32) : Array(UInt8)
      rotated = [word[1], word[2], word[3], word[0]]
      rotated.map! { |byte| SBOX[byte] }
      rotated[0] ^= RCON[iteration]
      rotated
    end

    private def append_word(expanded : Array(UInt8), word : Array(UInt8), source : Int32)
      4.times { |index| expanded << (word[index] ^ expanded[source + index]) }
    end

    private def substitute(data : Bytes, box : Bytes) : Bytes
      Bytes.new(data.size) { |index| box[data[index]] }
    end

    private def shift_rows(data : Bytes) : Bytes
      Bytes.new(BLOCK_SIZE) do |index|
        column = index // 4
        row = index % 4
        data[((column + row) & 3) * 4 + row]
      end
    end

    private def shift_rows_inverse(data : Bytes) : Bytes
      Bytes.new(BLOCK_SIZE) do |index|
        column = index // 4
        row = index % 4
        data[((column - row) & 3) * 4 + row]
      end
    end

    private def mix_columns(data : Bytes, inverse : Bool) : Bytes
      output = Bytes.new(BLOCK_SIZE)
      4.times do |column|
        offset = column * 4
        a = data[offset]
        b = data[offset + 1]
        c = data[offset + 2]
        d = data[offset + 3]
        if inverse
          output[offset] = multiply(a, 14) ^ multiply(b, 11) ^ multiply(c, 13) ^ multiply(d, 9)
          output[offset + 1] = multiply(a, 9) ^ multiply(b, 14) ^ multiply(c, 11) ^ multiply(d, 13)
          output[offset + 2] = multiply(a, 13) ^ multiply(b, 9) ^ multiply(c, 14) ^ multiply(d, 11)
          output[offset + 3] = multiply(a, 11) ^ multiply(b, 13) ^ multiply(c, 9) ^ multiply(d, 14)
        else
          output[offset] = multiply(a, 2) ^ multiply(b, 3) ^ c ^ d
          output[offset + 1] = a ^ multiply(b, 2) ^ multiply(c, 3) ^ d
          output[offset + 2] = a ^ b ^ multiply(c, 2) ^ multiply(d, 3)
          output[offset + 3] = multiply(a, 3) ^ b ^ c ^ multiply(d, 2)
        end
      end
      output
    end

    private def multiply(value : UInt8, factor : Int32) : UInt8
      a = value.to_i
      b = factor
      result = 0
      8.times do
        result ^= a if b.odd?
        high_bit = a & 0x80
        a = (a << 1) & 0xff
        a ^= 0x1b unless high_bit == 0
        b >>= 1
      end
      result.to_u8
    end

    private def transform_blocks(data : Bytes, trim_to_input = false, &block : Bytes -> Bytes) : Bytes
      output = IO::Memory.new
      each_block(data) { |part, _offset| output.write(yield part) }
      result = output.to_slice
      trim_to_input && result.size > data.size ? copy(result[0, data.size]) : result
    end

    private def each_block(data : Bytes, &block : Bytes, Int32 ->)
      offset = 0
      while offset < data.size
        size = Math.min(BLOCK_SIZE, data.size - offset)
        yield data[offset, size], offset
        offset += size
      end
    end

    private def zero_pad(data : Bytes) : Bytes
      return copy(data) if data.size == BLOCK_SIZE
      output = Bytes.new(BLOCK_SIZE, 0_u8)
      output[0, data.size].copy_from(data)
      output
    end

    private def xor(left : Bytes, right : Bytes) : Bytes
      size = Math.min(left.size, right.size)
      Bytes.new(size) { |index| left[index] ^ right[index] }
    end

    private def increment(data : Bytes) : Bytes
      result = copy(data)
      (result.size - 1).downto(0) do |index|
        if result[index] == 0xff
          result[index] = 0
        else
          result[index] += 1
          break
        end
      end
      result
    end

    private def ghash(subkey : Bytes, data : Bytes) : Bytes
      unless data.size % BLOCK_SIZE == 0
        raise CryptoError.new("GHASH input must be block aligned")
      end

      last = Bytes.new(BLOCK_SIZE, 0_u8)
      each_block(data) do |part, _offset|
        last = block_product(xor(last, part), subkey)
      end
      last
    end

    private def block_product(left : Bytes, right : Bytes) : Bytes
      unless left.size == BLOCK_SIZE && right.size == BLOCK_SIZE
        raise CryptoError.new("GHASH blocks must be 16 bytes")
      end

      value = copy(right)
      product = Bytes.new(BLOCK_SIZE, 0_u8)
      left.each do |byte|
        7.downto(0) do |bit|
          product = xor(product, value) unless byte & (1 << bit) == 0
          reduce = value[-1].odd?
          value = shift_block(value)
          value[0] ^= 0xe1_u8 if reduce
        end
      end
      product
    end

    private def shift_block(data : Bytes) : Bytes
      carry = 0
      Bytes.new(data.size) do |index|
        value = data[index].to_i
        value |= 0x100 unless carry == 0
        carry = value & 1
        (value >> 1).to_u8
      end
    end

    private def uint64_bytes(value : UInt64) : Bytes
      Bytes.new(8) { |index| ((value >> ((7 - index) * 8)) & 0xff).to_u8 }
    end

    private def secure_compare(left : Bytes, right : Bytes) : Bool
      return false unless left.size == right.size
      difference = 0_u8
      left.size.times { |index| difference |= left[index] ^ right[index] }
      difference == 0
    end

    private def append(*parts : Bytes) : Bytes
      total = parts.sum(&.size)
      output = Bytes.new(total)
      offset = 0
      parts.each do |part|
        output[offset, part.size].copy_from(part)
        offset += part.size
      end
      output
    end

    private def copy(data : Bytes) : Bytes
      Bytes.new(data.size) { |index| data[index] }
    end

    private def to_bytes(data : Array(UInt8)) : Bytes
      Bytes.new(data.size) { |index| data[index] }
    end
  end
end
