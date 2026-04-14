# frozen_string_literal: true

require_relative "lib/omq/compression/zstd/version"

Gem::Specification.new do |s|
  s.name        = "omq-rfc-zstd"
  s.version     = OMQ::Compression::Zstd::VERSION
  s.authors     = ["Patrik Wenger"]
  s.email       = ["paddor@gmail.com"]
  s.summary     = "Transparent Zstandard compression for OMQ (ZMTP extension)"
  s.description = "Negotiated, transparent per-frame Zstd compression with optional shared " \
                  "dictionary for the OMQ pure-Ruby ZeroMQ library."
  s.homepage    = "https://github.com/paddor/omq-rfc-zstd"
  s.license     = "ISC"

  s.required_ruby_version = ">= 3.3"

  s.files = Dir["lib/**/*.rb", "README.md", "RFC.md", "LICENSE"]

  s.add_dependency "omq",           ">= 0.19.3"
  s.add_dependency "protocol-zmtp", ">= 0.7"
  s.add_dependency "rzstd",         ">= 0.2"
end
