# ZMTP-Zstd: Transparent Zstandard Compression for ZMTP

| Field | Value |
|----------|----------------------------------------------------|
| Status | Draft |
| Editor | Patrik Wenger |
| Requires | [RFC 37/ZMTP 3.1](https://rfc.zeromq.org/spec/37/) |
| Extends | ZMTP 3.1 message frames over `tcp://` |

## 1. Abstract

ZMTP-Zstd is a negotiated, transparent, per-frame Zstandard compression
extension for ZMTP 3.1 message frames. Peers advertise compression support
via a READY property during the handshake. When both peers advertise a
matching profile, message frame bodies are compressed individually on the
wire, optionally using a shared dictionary. The dictionary may be supplied
out of band, sent over the wire once via the `ZDICT` command frame, or
trained automatically by the sender from the first 1000 messages (or 100
KiB of plaintext) of the connection. Peers that do not advertise
compression see a normal, uncompressed ZMTP 3.1 stream -- the extension is
fully backwards compatible.

## 2. Motivation

Modern general-purpose compressors -- Zstandard in particular -- have closed
the gap between "fast enough to ignore" and "saves real bytes". At its
fast-strategy (negative) levels Zstandard encodes in single-digit
microseconds per kilobyte, decompresses faster still, and on
dictionary-trained workloads compresses small frames to a fraction of
their size. For most ZMTP deployments compression can now be treated as
almost free CPU-wise, while still recovering large fractions of the wire
budget.

Network-bound or bandwidth-constrained deployments (publish/subscribe
fan-out, IoT, cross-region replication) can trade a small amount of CPU for
a large amount of wire time. Zstandard at low levels is fast at the
sender, very fast at the receiver, and its dictionary mode is a good fit
for the small-message profile typical of ZMQ workloads.

ZMTP applications today either accept the wire cost or layer ad-hoc,
per-payload compression into the application format. The latter requires
the application to opt in on both sides and bakes the compression into the
payload rather than the transport. ZMTP-Zstd replaces it with a
transport-level negotiation that any ZMTP application benefits from
without changes to the payload.

## 3. Goals and Non-goals

### 3.1 Goals

- Transparent to application code: send / receive operations see plaintext.
- Per-frame sender decision: opt out for short or incompressible frames.
- Backwards compatible with any ZMTP 3.1 peer that does not advertise
  compression.
- Works for legacy multi-frame socket types (PUSH/PULL, PUB/SUB, ...) and
  draft single-frame types alike.
- Small-message-friendly via an optional shared dictionary, either explicit
  or automatically trained.
- Algorithm-agnostic negotiation surface: future RFCs can add `lz4:`,
  `brotli:`, ... profiles to the same READY property without obsoleting this
  one.

### 3.2 Non-goals

- New ZMTP mechanism, new socket type, new greeting, new frame flag bit.
- Compression of the ZMTP greeting or non-`ZDICT` command frames (READY,
  SUBSCRIBE, PING, ...).
- `inproc://` (zero-copy -- compression is pure overhead) or `ipc://`
- Replacing or weakening CurveZMQ or any other security mechanism. See Sec. 9.
- **Streaming / context-takeover compression**, in the style of
  WebSocket `permessage-deflate`. Zstandard supports it via streaming
  frames or raw-content prefix dictionaries, where each compressed
  message inherits the LZ77 history of its predecessors. That mode is
  more efficient on streams of similar messages than per-frame
  dictionary compression, but trades away the per-frame independence
  that this RFC relies on (any frame decodable in isolation,
  drop-tolerant under HWM, no head-of-line dependency on a previous
  frame). A future RFC could define a separate profile (e.g.
  `zstd:stream`) for it; this RFC deliberately does not.

### 3.3 Why Zstandard

Zstandard at low levels matches LZ4 on encode latency, beats it
substantially on decompression speed and on ratio at every realistic ZMQ
payload size, and has a first-class dictionary story. The decompression
advantage is particularly important for the fan-out patterns ZMQ is built
around (PUB/SUB, RADIO/DISH): the publisher pays one compress, every
subscriber pays decompress, so per-subscriber CPU dominates the total
budget.

### 3.4 Compression level

The default level is **-3** (Zstandard fast strategy). At this level the
encoder cost is in the low single-digit microseconds per kilobyte across
all measured payload sizes, and the achieved ratio is within a few
percent of level 3 once a dictionary is in play. The level is a sender
choice and is not negotiated -- the receiver decodes any valid
Zstandard frame regardless of the level used to encode it.
Implementations MUST support negative levels (the "fast" strategy) and
SHOULD expose the level as a per-socket configuration knob.

Empirically, on lorem-ipsum payloads with a 512 B shared dictionary:

| level | strategy | typical c+d (1 KB, dict) | typical ratio (1 KB, dict) |
|-------|----------|--------------------------|----------------------------|
| -3 | fast | 2.9 us | 0.165 |
| -1 | fast | 3.8 us | 0.157 |
| 1 | normal | 6.7 us | 0.121 |
| 3 | normal | 2.9 us | 0.124 |
| 9 | high | 11.2 us | 0.121 |

Levels above 5 are not recommended for transparent per-frame compression:
the encoder cost grows steeply with no meaningful ratio improvement on the
small payloads typical of ZMQ workloads. Decompression speed is
independent of the compression level used by the sender.

### 3.5 Recommended profiles by messaging pattern

This section is informative, not normative. All recommendations assume
the default level of -3.

| Pattern | Recommendation |
|-----------------------------------------------|---------------------------------|
| Fan-out (PUB/SUB, XPUB/XSUB, RADIO/DISH) | `zstd:dict:auto` |
| Fan-in (many PUSH -> 1 PULL, DEALER -> ROUTER) | `zstd:dict:auto` |
| Symmetric small/medium (PUSH/PULL, REQ/REP, PAIR, <=4 KB) | `zstd:dict:auto` |
| Symmetric large (>=16 KB) | `zstd:none` |
| One-shot tiny messages, no dictionary plausible | `zstd:none` |
| Co-administered peers with a known schema | `zstd:dict:sha1:<hex>` |

The fan-out recommendation is based on the per-subscriber decompress
advantage compounding linearly with subscriber count. The large-message
recommendation reflects that the dictionary advantage shrinks once the
payload is much larger than the dictionary itself.

## 4. Terminology

| Term | Meaning |
|-------------|----------------------------------------------------------------------------|
| Profile | A string naming a compression scheme, e.g. `zstd:none` or `zstd:dict:sha1:<hex>` |
| Dictionary | A shared byte string used as a preamble to the Zstandard compressor |
| Sentinel | The 4-byte prefix on every post-negotiation message frame body (Sec. 6) |
| Uncompressed frame | A post-negotiation message frame whose sentinel is `00 00 00 00` |
| Compressed frame | A post-negotiation message frame whose first 4 bytes are the Zstandard magic `28 B5 2F FD` |
| Aware peer | A peer that advertises an `X-Compression` READY property |
| Unaware peer| A peer that does not advertise an `X-Compression` READY property |
| `ZDICT` frame | A ZMTP command frame, command name `ZDICT`, body = raw dictionary bytes |

## 5. Handshake Negotiation

### 5.1 The `X-Compression` READY property

An aware peer MUST include an `X-Compression` property in its READY
command. The property value is a comma-separated list of profile strings,
in preference order (most preferred first):

```
X-Compression: zstd:dict:auto, zstd:dict:sha1:7f3a..., zstd:none
```

Profile strings are ASCII, case-sensitive, with no embedded whitespace.
Implementations MUST tolerate (and ignore) profile names they do not
understand -- this is the forward-compatibility hook for future algorithms
(`lz4:dict:auto`, `brotli:none`, ...).

The property name `X-Compression` is deliberately algorithm-neutral. Every
profile carries its algorithm in its prefix, and the on-wire sentinel
disambiguates encoded frames at the byte level (Sec. 6.1). New compression
algorithms can be added by separate RFCs that define new profile strings
under the same property name.

### 5.2 Matching

Each peer intersects its own advertised list with the peer's, in its own
preference order, and selects the first matching profile. The selected
profile applies to **both directions** of the connection. This RFC does
not define asymmetric pairings (different algorithms or different
profiles per direction); a future RFC could lift that restriction.

Implementations SHOULD order their advertised list so that concrete
dictionaries win over auto-trained ones: `zstd:dict:sha1:<hex>` first,
then `zstd:dict:inline`, then `zstd:dict:auto`, then `zstd:none`. A peer
that has a configured dictionary but also supports `zstd:dict:auto` will
then converge on its existing dictionary instead of waiting for an
auto-training cycle.

If the intersection is empty, the connection falls back to plaintext ZMTP
3.1 -- the connection still succeeds, no compression is applied.
Implementations that expose a connection-monitoring facility MAY surface
this outcome through it.

If only one peer advertises `X-Compression`, the connection falls back to
plaintext (no peer can decode something the other side does not
understand).

### 5.3 Dictionary identity

The `zstd:dict:sha1:<hex>` profile carries the SHA-1 hex digest of the
dictionary bytes. Two peers select this profile only if they advertise the
same digest, which means the dictionary each side loaded has the same
content. Mismatched dictionaries -> no match -> fallback.

SHA-1 is used because the digest is purely for fingerprinting, not
security: collision resistance is not a property the dictionary identity
needs, and SHA-1 is universally available. Future RFCs that prefer a
different hash MUST register a new profile string with a different
prefix (e.g. `zstd:dict:xxh64:<hex>`); this RFC's `zstd:dict:sha1:`
profile is fixed to SHA-1 so that two peers advertising the same digest
can be sure they computed it the same way.

## 6. Frame Format

### 6.1 Sentinel values

A sentinel is the first 4 bytes of a post-negotiation message frame body.

| Sentinel (hex) | Meaning | Source of the bytes |
|------------------|--------------|---------------------|
| `00 00 00 00` | Uncompressed | Invented by this RFC. Four zero bytes are not a valid Zstandard frame magic, so they cannot collide with a real compressed frame. |
| `28 B5 2F FD` | Zstandard frame | The [official Zstandard frame magic](https://datatracker.ietf.org/doc/html/rfc8478#section-3.1.1). Not prepended by this RFC -- it is the first 4 bytes of the Zstandard frame the encoder already emitted. The receiver passes the **entire** frame body (including the magic) to the decoder. |

All other 4-byte values MUST cause the receiver to drop the connection
with an error of the form `ZMTP-Zstd: unknown sentinel`. This is the
extension slot for future compression RFCs: an LZ4 follow-up could reserve
`04 22 4D 18`, a Brotli follow-up could pick something distinguishable,
etc., and reuse the negotiation and framing rules from this RFC unchanged.

### 6.2 Why the Zstandard magic works as a sentinel

The Zstandard frame magic `28 B5 2F FD` is fixed at the start of any valid
Zstandard frame. A receiver that sees those bytes at offset 0 of a frame
body knows the sender intended a compressed frame. A real uncompressed
payload whose first 4 bytes happen to be `28 B5 2F FD` is handled by Sec. 6.4
step 2: the sender prepends `00 00 00 00` and emits 4 + N bytes. The
receiver decodes the `00 00 00 00` sentinel, skips it, and hands the
remaining N bytes (starting with `28 B5 2F FD`) to the application as
plaintext. No ambiguity.

### 6.3 Uncompressed sentinel `00 00 00 00`

```
+-------------+------------------+
| 00 00 00 00 | plaintext payload|
| (4 B) | (N bytes) |
+-------------+------------------+
```

The sender uses this sentinel when it decides, per Sec. 6.4, not to compress
the frame. The 4-byte overhead is the price of per-frame selective
compression without an extra flag bit in the ZMTP frame header.

### 6.4 Sender Rules

For each outgoing message frame, the sender proceeds as follows:

1. If no profile was negotiated for this direction, emit the frame
   plaintext with no sentinel (standard ZMTP 3.1).
2. Compute `min`:
   - if a dictionary is currently installed: `min = 64`
   - otherwise (`zstd:none`, or `zstd:dict:auto` before training):
     `min = 512`

   These are conservative starting points based on lorem-ipsum
   measurements. Implementations MAY tune them downward (potentially to
   `0` in the dictionary case) if their workload measurements justify it.
3. If `plaintext_bytesize < min`, prepend `00 00 00 00` and emit. Short
   frames are not worth the sentinel + compressor overhead.
4. Otherwise, run the Zstandard encoder. The encoder MUST be configured
   to write the `Frame_Content_Size` field in the Zstandard frame header
   (RFC 8878 Sec. 3.1.1.1.2). If the compressed output's bytesize is greater
   than or equal to `plaintext_bytesize - 4` (net saving <= 0 after
   accounting for the 4-byte sentinel of the uncompressed alternative),
   prepend `00 00 00 00` and emit the plaintext. Otherwise emit the
   Zstandard frame as-is -- its first 4 bytes ARE the sentinel.
5. Multi-part messages: each frame in the message is compressed
   independently. The ZMTP MORE flag is carried on the wire frame header
   as normal.

The threshold split (64 with dict, 512 without) reflects empirical
measurement: without a dictionary, Zstandard cannot compress
lorem-ipsum-shaped text below ~512 B; with a dictionary, even 64 B
payloads compress to ~20 B.

### 6.5 Receiver Rules

For each incoming message frame, the receiver proceeds as follows:

1. If no profile was negotiated for this direction, the body is plaintext
   (standard ZMTP 3.1). Return as-is.
2. Otherwise, read the first 4 bytes of the body as the sentinel. If the
   body is shorter than 4 bytes, drop the connection with `ZMTP-Zstd:
   short frame`.
3. If the sentinel is `00 00 00 00`, the remaining `N - 4` bytes are
   plaintext. Return them.
4. If the sentinel is `28 B5 2F FD`, the body is a complete Zstandard
   frame. The receiver MUST read the frame's `Frame_Content_Size` field
   from the Zstandard header BEFORE calling the decoder. If the field is
   absent, drop the connection with `ZMTP-Zstd: missing content size`.
   If the connection enforces a maximum message size, the receiver MUST
   add this frame's declared content size to the running decompressed
   total for the current multipart message (frames chained by the ZMTP
   MORE flag). If that running total would exceed the maximum, drop the
   connection with `ZMTP-Zstd: decompressed message size exceeds maximum`
   without invoking the decoder. The decoder MUST then be invoked in a
   mode that aborts as soon as it would write more bytes than this
   frame's declared `Frame_Content_Size`; on such an abort, drop the
   connection with `ZMTP-Zstd: content size mismatch`.
5. Any other sentinel value: drop the connection with `ZMTP-Zstd: unknown
   sentinel`.

The receiver's view of the maximum message size always refers to the
**decompressed** plaintext, summed across all frames of a multipart
message. A multipart message whose total wire length is smaller than the
maximum but whose total decompressed size would exceed it MUST be
rejected, and the check MUST happen before any decoder invocation that
could exceed the limit.

## 7. Profiles

### 7.1 `zstd:none`

No dictionary. Per-frame opportunistic compression with the 512 B sender
threshold. The simplest profile and the only one that requires no
out-of-band coordination or in-band setup.

**Use it when**: peers cannot agree on a dictionary file and
`zstd:dict:auto` is not desired (e.g. because the application controls
message format and wants deterministic, level-only tuning).

### 7.2 `zstd:dict:sha1:<hex>`

A shared dictionary, agreed out of band (typically a file shared by
configuration management). Both peers load the same dictionary bytes
locally, derive `dict:sha1:<hex>` from the SHA-1 hex digest of the
dictionary, and advertise it. The handshake matches only when the digests
are byte-equal.

**Use it when**: peers are co-administered (same deployment, shared secret
store) and the dictionary is part of the application's release artifact.

### 7.3 `zstd:dict:inline`

A dictionary supplied by one peer and shipped to the other over the wire,
once, via a `ZDICT` command frame (Sec. 8). After both peers have a dictionary
loaded, the connection behaves identically to `zstd:dict:sha1:<hex>` for
the rest of its lifetime.

The peer that has a configured dictionary is the one that sends `ZDICT`.
The receiver of a `ZDICT` frame loads the dictionary into its **decoder**
context only; it does not implicitly start using that dictionary on its
own outgoing frames. If both peers have a configured dictionary they
each send their own; each direction then uses its sender's dictionary
(for both encode and decode on that side). The common deployment is
one-directional (publisher ships its dictionary; subscriber decodes
with it and sends nothing back), so this asymmetry is rarely visible.

**Use it when**: one side has the dictionary (publisher, gateway, server)
and the other is a thin client that should not need to hold the
dictionary file.

### 7.4 `zstd:dict:auto`

No dictionary at connect time. The sender:

1. Compresses the first messages with `zstd:none` semantics (the 512 B
   sender threshold applies -- small frames go plaintext, large frames go
   no-dict-Zstandard). The sender SHOULD prefer small frames as training
   samples, since dictionaries primarily benefit small frames; an
   implementation MAY skip frames above some size when filling the
   sample buffer.
2. Buffers each plaintext sample, until it has accumulated either
   **1000 messages** OR **100 KiB** of plaintext, whichever comes first.
3. Trains a Zstandard dictionary from the buffered samples and discards
   the buffer.
4. Sends the trained dictionary bytes as a `ZDICT` command frame on every
   connection that negotiated `zstd:dict:auto` and has not yet received
   one.
5. Switches to dict-bound compression with the trained dictionary for
   all subsequent message frames on those connections.

The receiver, on receiving a `ZDICT` command frame, loads the dictionary
into its decoder context and applies it to all subsequent message frames
on that connection.

#### Auto-dict scope

The dictionary's scope is **socket-wide**, not per-connection. A sender
pools sample frames across **all** outgoing connections of one socket
into a single buffer. Once trained, the dictionary is sent via `ZDICT`
to every current connection that negotiated `zstd:dict:auto`, and is
remembered for every future connection of that socket: newly opened or
newly accepted connections that negotiate `zstd:dict:auto` receive the
dictionary as a `ZDICT` command frame at the start of their session,
before any compressed message frame.

Socket-wide scope is most valuable for sockets whose connections are
short-lived or churn frequently (reconnecting subscribers, request/reply
clients, transient peers). With per-connection training each new
connection would have to re-accumulate samples from scratch, and a
connection that dies before reaching the training threshold would never
get a dictionary at all. With socket-wide scope, the very first
compressed frame on a freshly-opened connection already benefits from
the dictionary trained by its predecessors.

The dictionary is never persisted across socket restarts: there is no
on-disk format and no cross-process sharing.

#### Receiver-side cost

Each compressed frame must be decoded against the dictionary that was
loaded for that specific connection. A receive-side socket with N
inbound connections that all negotiated `zstd:dict:auto` therefore
holds **N independently loaded decoder dictionaries**, one per
connection, because each peer trains its own dictionary from its own
sample set and ships it via that connection's `ZDICT` frame. The trained
bytes diverge across senders almost immediately, so dedup-by-content is
unlikely to recover anything in practice. Implementations MAY still
hash incoming `ZDICT` bodies and intern matching ones; the wire format
neither enables nor forbids it.

A deployment that wants explicit, negotiated dictionary identity across
many peers (so the receiver can intern by digest with no ambiguity)
SHOULD use `zstd:dict:sha1:<hex>` instead.

**Use it when**: zero configuration is more important than maximum
dictionary quality.

#### Edge cases

- **Late joiners**: covered by socket-wide scope above. A connection
  that opens after the socket has already trained its dictionary
  receives a `ZDICT` command frame immediately after the ZMTP handshake
  completes, before any compressed message frame on that connection.
- **Trainer failure**: if dictionary training returns an error (the
  sample set was too small or too uniform), the sender MUST stay in
  `zstd:none` mode for the rest of the socket's lifetime. It MUST NOT
  retry training.
- **Threshold trigger order**: the message-count and byte-count
  thresholds are independent. Training fires the moment **either** is
  met. A workload of one 100 KiB message triggers training after the
  first message; a workload of 1000 64-byte messages triggers training
  after exactly 1000 frames.

## 8. The `ZDICT` command frame

A new ZMTP command frame:

| Field | Value |
|----------|--------------------------------------------------------|
| Type | ZMTP command frame (frame header `COMMAND` bit set) |
| Name | The 5 ASCII bytes `ZDICT`, encoded per RFC 37 as the 1-byte length `05` followed by `ZDICT` (6 bytes on the wire) |
| Body | Raw dictionary bytes, no framing, no length prefix |

The command frame's body is the dictionary as it should be passed to the
Zstandard decoder's dictionary-load operation. The `ZDICT` command frame
is used by both `zstd:dict:inline` (sender ships a configured dictionary
at connect time) and `zstd:dict:auto` (sender ships a trained dictionary
mid-stream).

A `ZDICT` command frame MAY appear at most once per direction per
connection. Receiving a second `ZDICT` MUST drop the connection with
`ZMTP-Zstd: duplicate ZDICT`. Receiving a `ZDICT` on a connection whose
negotiated profile is `zstd:none` or `zstd:dict:sha1:<hex>` MUST drop the
connection with `ZMTP-Zstd: unexpected ZDICT`.

A `ZDICT` command frame MUST NOT be larger than **64 KiB**. The cap is
deliberately conservative: the Zstandard project recommends a roughly
100:1 training-sample to dictionary ratio, so a 100 KiB sample budget
(Sec. 7.4) yields a ~1 KiB trained dictionary, and even hand-tuned
dictionaries for small-message workloads are typically a few hundred
bytes to a few kilobytes. 64 KiB leaves an order of magnitude of
headroom while preventing a peer from forcing an arbitrarily large
allocation. Implementations that need larger dictionaries should use
`zstd:dict:sha1:<hex>`, which ships the dictionary out of band and
imposes no in-band size limit.

## 9. Security Considerations

### 9.1 Compression combined with encryption (CRIME / BREACH)

Combining length-revealing compression with a secure channel that carries
attacker-influenced plaintext enables CRIME- and BREACH-style side-channel
attacks: an attacker who can inject chosen bytes into the plaintext and
observe the ciphertext length can extract secrets byte by byte.

Therefore: **implementations MUST refuse to enable ZMTP-Zstd on a
connection whose ZMTP mechanism is anything other than NULL or PLAIN.** In
particular, ZMTP-Zstd MUST NOT coexist with CurveZMQ on the same
connection.

An application that deliberately accepts the risk (because it controls
all plaintext and no attacker can inject bytes) MAY override this with an
explicit, loud opt-in. Implementations that expose a connection-
monitoring facility SHOULD surface such an override through it.

### 9.2 Length side-channel

Compression makes the wire length of a frame depend on its content. An
on-path observer that can see the wire bytes can therefore learn
something about the plaintext from the compressed length alone, even
though ZMTP-Zstd itself provides no confidentiality. Deployments that
care about traffic analysis MUST NOT rely on ZMTP-Zstd to hide payload
shape.

### 9.3 Dictionary contents

The dictionary is part of the trust boundary in `zstd:dict:inline` and
`zstd:dict:auto`: the receiver loads bytes the peer chose. The
Zstandard reference dictionary loader is hardened against malformed
inputs, but implementations MUST enforce the 64 KiB cap on `ZDICT` frames
(Sec. 8) and SHOULD NOT cache received dictionaries across connections.

### 9.4 Decompression bombs

A small compressed frame can decompress to many MB of plaintext. The
sender rules in Sec. 6.4 do not prevent a malicious peer from sending such a
frame. The receiver rules in Sec. 6.5 mitigate this in two ways:

1. Every compressed frame MUST carry `Frame_Content_Size` in its
   Zstandard header (sender rule Sec. 6.4 step 4). The receiver checks the
   declared total against the connection's maximum message size before
   invoking the decoder, so a bomb is rejected on its header alone.
2. The decoder is invoked in a bounded mode that aborts the moment it
   would write more bytes than `Frame_Content_Size` declared, so a peer
   that lies in the header still cannot expand a frame past its declared
   size.

Implementations SHOULD set a conservative maximum message size whenever
`X-Compression` is enabled, even if they would otherwise leave it
unbounded.

## 10. Interoperability and Backwards Compatibility

### 10.1 Unaware peers

A ZMTP 3.1 peer that does not understand the `X-Compression` property
simply ignores it. Its own READY command will not contain the property,
the aware side will see no match, and the connection runs in plaintext.
No handshake-level failure.

### 10.2 Aware peers with no overlap

If both peers advertise `X-Compression` but their profile lists do not
intersect, the connection runs in plaintext. Implementations that expose
a connection-monitoring facility SHOULD surface this outcome through it,
so that deployment mistakes (wrong dictionary, wrong profile) are
discoverable.

### 10.3 Forward compatibility

All implementations MUST be liberal about unknown profiles in the peer's
`X-Compression` list. An unknown profile is ignored during matching and
is not a protocol error. Future RFCs add new profiles by:

1. Picking a profile string with a clear algorithm prefix (e.g.
   `lz4:dict:auto`).
2. Reserving a new 4-byte sentinel (the algorithm's frame magic, ideally).
3. Defining sender / receiver rules for that sentinel.
4. Publishing the spec.

No central registry is needed: profile-string and sentinel collisions are
caught at code-review time when the new RFC is being written, and the
algorithm prefix in the profile string makes the namespace effectively
self-managing.

## 11. Constants

```
SENTINEL_UNCOMPRESSED = 00 00 00 00 (4 bytes)
SENTINEL_ZSTD_FRAME = 28 B5 2F FD (4 bytes, official Zstandard frame magic)

PROPERTY_NAME = "X-Compression"

DEFAULT_LEVEL = -3

MIN_COMPRESS_BYTES_NO_DICT = 512
MIN_COMPRESS_BYTES_DICT = 64

AUTO_DICT_SAMPLE_COUNT = 1000
AUTO_DICT_SAMPLE_BYTES = 100 * 1024
DICT_FRAME_MAX_SIZE = 64 * 1024

PROFILE_NONE = "zstd:none"
PROFILE_DICT_PREFIX = "zstd:dict:sha1:"
PROFILE_DICT_INLINE = "zstd:dict:inline"
PROFILE_DICT_AUTO = "zstd:dict:auto"
```

## 12. References

- [RFC 37 / ZMTP 3.1](https://rfc.zeromq.org/spec/37/) -- underlying transport
- [RFC 8478 -- Zstandard Compression and the application/zstd Media Type](https://datatracker.ietf.org/doc/html/rfc8478)
- [Zstandard dictionary builder](https://github.com/facebook/zstd/blob/dev/lib/dictBuilder/zdict.h)
- [CRIME attack](https://en.wikipedia.org/wiki/CRIME) -- compression-side-channel attack on TLS
- [BREACH attack](https://en.wikipedia.org/wiki/BREACH) -- HTTP-layer variant of the same family
