# frozen_string_literal: true

module Avsb
  module Core
    # MurmurHash3_x86_32 — deterministic 32-bit hash for visitor bucketing.
    #
    # Ported verbatim from packages/avsb-core/src/hash.ts.  All intermediate
    # values are masked to 32 bits with & 0xFFFFFFFF to replicate JavaScript's
    # unsigned-32-bit integer semantics (Ruby integers are arbitrary precision).
    module Hash
      C1 = 0xcc9e2d51
      C2 = 0x1b873593
      MASK32 = 0xFFFFFFFF

      # Compute MurmurHash3_x86_32 of +key+ (String, UTF-8 bytes) with +seed+.
      # Returns an unsigned 32-bit integer.
      def self.murmurhash3(key, seed = 0)
        bytes = key.encode("UTF-8").bytes
        len   = bytes.length
        h1    = seed & MASK32

        nblocks = len >> 2

        # Body — process 4-byte blocks
        nblocks.times do |i|
          i4 = i * 4
          k1 = (bytes[i4]     & 0xff)        |
               ((bytes[i4 + 1] & 0xff) << 8)  |
               ((bytes[i4 + 2] & 0xff) << 16) |
               ((bytes[i4 + 3] & 0xff) << 24)
          k1 &= MASK32

          k1 = imul32(k1, C1)
          k1 = ((k1 << 15) | (k1 >> 17)) & MASK32
          k1 = imul32(k1, C2)

          h1 ^= k1
          h1  = ((h1 << 13) | (h1 >> 19)) & MASK32
          h1  = (imul32(h1, 5) + 0xe6546b64) & MASK32
        end

        # Tail — remaining bytes
        tail = nblocks * 4
        k1   = 0

        remaining = len & 3
        if remaining >= 3
          k1 ^= (bytes[tail + 2] & 0xff) << 16
        end
        if remaining >= 2
          k1 ^= (bytes[tail + 1] & 0xff) << 8
        end
        if remaining >= 1
          k1 ^= bytes[tail] & 0xff
          k1 = imul32(k1, C1)
          k1 = ((k1 << 15) | (k1 >> 17)) & MASK32
          k1 = imul32(k1, C2)
          h1 ^= k1
        end

        # Finalization mix
        h1 ^= len
        h1 &= MASK32
        h1 ^= h1 >> 16
        h1 &= MASK32
        h1  = imul32(h1, 0x85ebca6b)
        h1 ^= h1 >> 13
        h1 &= MASK32
        h1  = imul32(h1, 0xc2b2ae35)
        h1 ^= h1 >> 16
        h1 &= MASK32

        h1
      end

      # 32-bit truncating multiply — replicates Math.imul() from JavaScript.
      def self.imul32(a, b)
        # Mask inputs to 32 bits, multiply, mask result to 32 bits.
        ((a & MASK32) * (b & MASK32)) & MASK32
      end
      private_class_method :imul32
    end
  end
end
