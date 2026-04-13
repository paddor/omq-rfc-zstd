# Changelog

## Unreleased

Initial release.

- RFC draft for `X-Compression` READY property and `ZDICT` command frame.
- `OMQ::RFC::Zstd::Compression` with `.none`, `.with_dictionary`, `.auto`.
- Transparent `CompressionConnection` wrapper installed after handshake.
- Per-direction compression negotiation (RFC §7.3).
- Auto-trained dictionaries shipped over a single `ZDICT` command frame.
- Integration tests against a real OMQ socket pair.
