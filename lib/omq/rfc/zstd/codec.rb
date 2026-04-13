# frozen_string_literal: true

require_relative "constants"

module OMQ
  module RFC
    module Zstd
      # Pure-function frame-body codec. Implements the sender/receiver rules
      # from RFC sections 6.4 and 6.5. Stateless: all state (dictionary,
      # profile, max_message_size) is passed in explicitly. Has no dependency
      # on Protocol::ZMTP::Connection, so this module is unit-testable in
      # isolation.
      module Codec
        module_function

        # Sender rule (RFC 6.4). Returns the bytes to place in the ZMTP
        # message-frame body.
        #
        # @param plaintext [String] frame payload as supplied by the user
        # @param compression [OMQ::RFC::Zstd::Compression] the negotiated
        #   send-direction compression object, or nil if no profile is active
        # @return [String] frame body bytes (always binary)
        def encode_part(plaintext, compression)
          plaintext = plaintext.b unless plaintext.encoding == Encoding::BINARY

          return plaintext if compression.nil?

          size = plaintext.bytesize
          if size < compression.min_compress_bytes
            return SENTINEL_UNCOMPRESSED + plaintext
          end

          compressed = compression.compress(plaintext)
          if compressed.bytesize >= size - SENTINEL_SIZE
            SENTINEL_UNCOMPRESSED + plaintext
          else
            compressed
          end
        end


        # Receiver rule (RFC 6.5). Returns the plaintext bytes for the user,
        # or raises on protocol violation.
        #
        # @param body [String] wire frame body bytes
        # @param compression [OMQ::RFC::Zstd::Compression] the negotiated
        #   recv-direction compression object, or nil if no profile is active
        # @param max_message_size [Integer, nil] socket's max_message_size
        # @return [String] plaintext bytes (binary)
        def decode_part(body, compression, max_message_size: nil)
          return body if compression.nil?

          if body.bytesize < SENTINEL_SIZE
            raise ShortFrameError, "ZMTP-Zstd: short frame"
          end

          sentinel = body.byteslice(0, SENTINEL_SIZE)

          case sentinel
          when SENTINEL_UNCOMPRESSED
            body.byteslice(SENTINEL_SIZE, body.bytesize - SENTINEL_SIZE)
          when SENTINEL_ZSTD_FRAME
            # Zstd frame magic IS the first 4 bytes of the body. Pass the
            # entire body (including the magic) to the decompressor.
            compression.decompress(body, max_message_size: max_message_size)
          else
            raise UnknownSentinelError,
                  "ZMTP-Zstd: unknown sentinel #{sentinel.unpack1('H*')}"
          end
        end
      end
    end
  end
end
