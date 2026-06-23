# cr-dlp Crystal Port

`cr-dlp` is a Python-free Crystal reimplementation of yt-dlp. The current
version is a development preview pinned to upstream commit `acf8ab7a6`.

## Current Status

Implemented:

- Frozen option, extractor, protocol, and embedded-test manifests.
- Metadata-driven parsing for the complete upstream option registry.
- Batch-file URL intake, saved `--load-info-json` replay through the normal
  pipeline, JSON/get-id print aliases, staged `--print-to-file`, and
  `--id` output-template shorthand.
- Explicit `--config-locations`/`--config-location` files and directories,
  nested configuration expansion, and `--no-config-locations` clearing.
- Crystal library API with ordered extractor, downloader, and postprocessor
  registries.
- Compatibility info dictionaries with typed accessors and runtime sidecars.
- Request director with a Crystal HTTP/TLS backend, environment and explicit
  HTTP/HTTPS/SOCKS4/SOCKS4a/SOCKS5/SOCKS5h proxies, proxy authentication,
  local or remote DNS, `NO_PROXY`, CONNECT tunnels, and nested TLS.
- Synchronous WebSocket request/response support for WS and WSS with text,
  binary, fragmented, ping/pong, close, cookie, header, subprotocol, TLS, and
  SOCKS4/SOCKS4a/SOCKS5/SOCKS5h behavior, plus the ffmpeg-backed
  `websocket_frag` downloader.
- Persistent Netscape cookie files with domain/path/secure matching,
  response-cookie updates, redirect handling, and session-cookie round trips.
- Request authentication for explicit username/password, URL credentials,
  netrc files, netrc command output, and the frozen
  `--no-check-certificates` TLS-verification option.
- Generic direct-media, local fixture, and Archive.org extractors.
- Opt-in local file URL/path extraction and copying via `--enable-file-urls`.
- Static and live HLS and DASH manifest parsing, variant selection, subtitles,
  byte ranges, HLS AES-128, dynamic DASH availability windows, resumable
  manifest refresh, sliding-window deduplication, and ordered fragment
  downloads.
- Pure Crystal AES-128/192/256 primitives with ECB, CBC, CTR, authenticated
  GCM, yt-dlp password-text decryption, padding compatibility, and an
  OpenSSL-accelerated CBC byte path with the Crystal implementation retained
  as the fallback.
- Subtitle selection across normal and automatic captions with regex language
  filters, format preferences, listing, inline/HTTP/HLS/DASH downloads,
  subtitle-specific templates and paths, `--skip-download` sidecars, and
  ffmpeg conversion to ASS, LRC, SRT, or WebVTT.
- Thumbnail listing, best-candidate fallback, all-thumbnail ID naming,
  thumbnail-specific templates and paths, `--skip-download` sidecars, and
  ffmpeg conversion mappings for JPEG, PNG, and WebP.
- ffmpeg subtitle embedding for MP4/MOV/M4A/WebM/Matroska with language and
  title metadata, plus cover-art embedding for MP3, Matroska, MP4-family,
  FLAC, Ogg, and Opus files. Ogg-family pictures use a native Crystal
  `METADATA_BLOCK_PICTURE` encoder. Implicit sidecars are removed after
  success while explicitly requested sidecars are retained.
- Format selection for quality and star aliases, nth choices, exact IDs,
  extensions, slash fallbacks, grouping, comma lists, `all`, and `mergeall`.
- Numeric and string format filters, including optional missing values,
  filesize units, regex matching, and negated string operators.
- Format sorting with default yt-dlp precedence, user and extractor fields,
  aliases, reverse order, caps, nearest-value targets, codec/container
  preferences, `--format-sort-force`, and `--prefer-free-formats`.
- Protocol-aware format availability probing with ranged HTTP requests,
  HLS/DASH fragment checks, lazy selected-format fallback,
  `--check-all-formats`, and extractor-marked risky format checks.
- Interactive `-f -` format selection with format listing, default selection,
  syntax/unavailable retries, EOF handling, and injectable library I/O.
- Multi-format selection and ffmpeg stream-copy merging with deterministic
  intermediate files, failure preservation, `--keep-video`, and multi-download
  orchestration for comma and `all` selections.
- Automatic transactional ffmpeg fixups for stretched aspect ratios, DASH
  M4A containers, MPEG-TS-in-MP4 HLS downloads, duplicate MOOV atoms,
  malformed timestamps, and durations, including `--fixup` policy handling.
- Transactional ffmpeg audio extraction, video remuxing, and video recoding
  with mapping rules, quality selection, overwrite behavior, source
  preservation, and rollback on failure.
- ffmpeg metadata embedding for common and custom tags, per-stream metadata,
  chapters, and MKV/MKA info-json attachments, including sidecar cleanup and
  real ffmpeg/ffprobe round-trip coverage.
- Staged metadata interpretation and regex replacement for all upstream
  postprocessor stages, including repeated actions, deprecated
  `--metadata-from-title`, and three-argument `--replace-in-metadata` parsing.
- Coordinator-level rejection and stopping controls for title, view, date, age,
  filesize, `--match-filters`, `--break-match-filters`,
  `--break-on-reject`, `--break-per-input`, and `--max-downloads`.
- Chapter removal with regex and timestamp ranges, SponsorBlock-compatible
  overlap/category arrangement, tiny-segment handling, external subtitle
  synchronization, concat demuxing, optional forced keyframes, and
  transactional rollback.
- Chapter splitting with chapter-specific templates and paths, optional forced
  keyframes, recorded chapter filepaths, temporary-to-home movement, and real
  ffmpeg/ffprobe coverage.
- SponsorBlock API retrieval with category aliases, duration validation,
  chapter marking, and removal handoff.
- Playlist and multi-video concatenation with stream compatibility checks,
  transactional ffmpeg output, dedicated templates and paths, and source
  preservation on failure.
- XDG/Dublin Core extended attributes with native Windows ADS support,
  Linux/macOS command backends, failure classification, and mtime preservation.
- Output templates with nested traversal and slices, alternatives, defaults,
  replacements, arithmetic, timestamp formatting, numeric padding, list/JSON
  conversions, generated fields, shell quoting, percent escaping,
  sanitization, paths, and filename trimming. The same renderer powers
  repeated video/playlist `--print` templates and field-name shorthand.
- HTTP, fixture, HLS, and DASH downloads, atomic `.part` files, resumable
  fragment state, output templates,
  progress hooks, postprocessor hooks, and `.info.json`.
- Streamed direct HTTP downloads with redirects, request headers, retries,
  Range resume, configured chunk-size downloads, HTTP Last-Modified mtime
  preservation, bounded `--test` downloads, and playlist processing.
- External downloader delegation for direct media and selected component
  downloads, including protocol/default downloader selection, common
  curl/wget/aria2c/ffmpeg argument defaults, supplemental args, and template
  expansion.
- Core pacing controls for request sleeps, media sleeps, subtitle sleeps,
  retry-sleep expressions, rate-limited writes, configured buffer sizes,
  progress hooks, progress templates, progress delta throttling,
  `--newline`, and `--no-progress`.
- Compatible cache-directory resolution, `--no-cache-dir`, and
  `--rm-cache-dir` maintenance behavior.
- Compatible download archive IDs, locked archive updates, pre-download
  skipping, and forced recording during simulation.
- Staged `--exec` commands and temporary-to-home media/sidecar movement,
  including subtitles, thumbnails, and info JSON.
- Description and internet-shortcut sidecars (`.description`, `.url`,
  `.webloc`, `.desktop`) in full and `--skip-download` sidecar-only runs.
- Extractor controls for listing descriptions, `--use-extractors`,
  `--force-generic-extractor`, and `--no-playlist`.
- Versioned JSON-RPC process-plugin manifest and client.
- JavaScript interpreter compatible with yt-dlp `jsinterp` for extractor
  scripts, including a hidden `--__jsinterp-eval` oracle entrypoint.
- Browser cookie import for Firefox, Safari, and Chromium-family browsers via
  `crystal-sqlite3`, including profile, keyring, container parsing, Safari
  `Cookies.binarycookies`, macOS keychain lookup, and Windows DPAPI/AES-GCM
  Chromium cookie decryption.
- Request impersonation via `curl-impersonate` binary delegation,
  `--impersonate`, and `--list-impersonate-targets`.
- Advanced output-template conversions (`h`, `B`, `U`, `S`) alongside the
  existing projection, list, JSON, decimal-suffix, and shell-quote support.
- Manifest-driven self-updater with local/file/HTTP artifacts, channel
  manifest resolution, detached RSA/SHA-256 manifest signatures, platform/arch
  selection, SHA-256 artifact verification, transactional executable
  replacement, and `-U`/`--update-to` CLI wiring.
- Release packaging script that emits raw updater artifacts, `cr-dlp`/`yt-dlp`
  archive payloads, SHA-256 metadata, and CI preview packages.
- Crystal specs and Python-vs-Crystal metadata/download differential smoke
  tests, including `differential_jsinterp.py`, browser-cookie fixtures,
  executable extractor fixture matchers, extractor fixture coverage reports,
  and the aggregate `crystal_test_gate.py`.

Not yet implemented:

- The remaining 1,869 frozen built-in extractor registrations beyond Generic
  and Archive.org. The opt-in `File` extractor is a Crystal runtime helper and
  is reported separately from the frozen baseline.
- Published official release-channel URLs and signing keys.

The preview intentionally reports `0.1.0-dev`; it does not claim stable
drop-in parity.

## Development

```text
python devscripts/export_crystal_baseline.py
crystal tool format --check src spec
crystal spec --error-trace
shards build --error-trace
python devscripts/differential_crystal.py
python devscripts/differential_jsinterp.py
python devscripts/package_crystal_release.py --binary bin/cr-dlp --out-dir dist
python devscripts/extractor_fixture_report.py --require-implemented-tested
python devscripts/crystal_test_gate.py --release --static --differential
```

Linux and macOS builds need `libsqlite3` available to the linker. On Windows,
install a `sqlite3.lib`/`sqlite3.dll` pair into `CRYSTAL_LIBRARY_PATH` or pass
equivalent `--link-flags` when building.

Try the first real extractor without downloading a full movie:

```text
bin/cr-dlp --list-formats https://archive.org/details/Cops1922/Cops-v2.mp4
bin/cr-dlp --test -f 0 -o "archive-test.%(ext)s" https://archive.org/details/Cops1922/Cops-v2.mp4
```

The generated files under `baseline/crystal/` are committed so production
builds do not need Python. `--list-extractors` reports only extractors that the
preview can execute; the full target registry remains in
`baseline/crystal/extractors.json`. Python remains only a development oracle.
