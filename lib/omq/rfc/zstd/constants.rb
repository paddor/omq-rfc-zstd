# frozen_string_literal: true

module OMQ
  module RFC
    module Zstd
      SENTINEL_UNCOMPRESSED = "\x00\x00\x00\x00".b.freeze
      SENTINEL_ZSTD_FRAME   = "\x28\xB5\x2F\xFD".b.freeze
      SENTINEL_SIZE         = 4

      PROPERTY_NAME         = "X-Compression"

      DEFAULT_LEVEL         = -3

      MIN_COMPRESS_BYTES_NO_DICT = 512
      MIN_COMPRESS_BYTES_DICT    = 64

      AUTO_DICT_SAMPLE_COUNT = 1000
      AUTO_DICT_SAMPLE_BYTES = 100 * 1024
      DICT_FRAME_MAX_SIZE    = 64 * 1024

      PROFILE_NONE        = "zstd:none"
      PROFILE_DICT_PREFIX = "zstd:dict:sha1:"
      PROFILE_DICT_INLINE = "zstd:dict:inline"
      PROFILE_DICT_AUTO   = "zstd:dict:auto"

      class Error < ::RuntimeError; end
      class ShortFrameError < Error; end
      class UnknownSentinelError < Error; end
      class DecompressedSizeExceedsMaxError < Error; end
      class DictMismatchError < Error; end
    end
  end
end
