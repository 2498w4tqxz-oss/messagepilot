# Files, reading and previews

MessagePilot preserves arbitrary file bytes with an authenticated upload → store → download API. Listed extensions select reading/preview strategies; an extension or MIME hint is not proof that a file is valid, safe or renderable. There is no measured “99% of all file types” guarantee.

## Enable storage

Add this to gateway configuration (paths are administrator-controlled, never supplied by agents):

```json
{
  "files": {
    "directory": "/absolute/private/messagepilot-files",
    "maxFileBytes": 536870912,
    "maxAccountBytes": 5368709120,
    "conversion": {
      "python": "/opt/homebrew/bin/python3",
      "tools": {
        "soffice": "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        "pdftotext": "/opt/homebrew/bin/pdftotext",
        "ffprobe": "/opt/homebrew/bin/ffprobe",
        "ffmpeg": "/opt/homebrew/bin/ffmpeg",
        "magick": "/opt/homebrew/bin/magick",
        "image": "/absolute/messagepilot/native/.build/messagepilot-image",
        "textutil": "/usr/bin/textutil",
        "tar": "/usr/bin/tar"
      }
    }
  }
}
```

Build the ImageIO helper with `swiftc scripts/image-converter.swift -o native/.build/messagepilot-image` after creating `native/.build`. Pillow is optional for image metadata/previews; the ImageIO helper handles Apple-native formats. Install/configure converters yourself; the gateway never installs tools from an uploaded file. Omit `conversion` to retain storage/download and native open-with behavior without running converters.

The current conversion runner requires macOS. It denies IP network access (Office may use local Unix IPC in a unique short-lived socket directory), restricts file data reads to system/tool resources and the isolated job, restricts writes to that job and its private IPC directory, removes inherited secrets, limits runtime/CPU/output size, and runs one conversion at a time. It is defense in depth, not a claim that every third-party parser is safe. Use a dedicated worker/VM for hostile multi-tenant uploads. Linux/container conversion is an integration direction, not implemented by this runner.

## HTTP contract

All paths below begin `/v1/accounts/:account/files`. Agent Bearer authentication is required on every request. Reads require `files.read`; writes/preparation/deletion require `files.write`. File access intersects the account and agent chat grants. A passkey card session grants no file access.

| Method/path                   | Behavior                                                                                                                                                    |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST ?chatId=...&name=...`   | Raw binary upload; exact chat, filename and Content-Length required. Optional `X-Content-SHA256` must match. Returns immutable file ID, bytes and hash.     |
| `GET ?chatId=...`             | Latest 200 files for this exact chat.                                                                                                                       |
| `GET /formats`                | Extension strategies, including generic fallback.                                                                                                           |
| `GET /:id`                    | Manifest, current preparation status and bounded read result.                                                                                               |
| `POST /:id/prepare`           | Prepare/cache a derivative asynchronously. `202` is acceptance, not completed rendering. Poll manifest. Concurrent different conversions return `409 busy`. |
| `GET /:id/read`               | Manifest plus extracted text/metadata/warnings. It does not launch conversion implicitly.                                                                   |
| `GET` or `HEAD /:id/download` | Exact original, attachment disposition, byte ranges (`206`/`416`).                                                                                          |
| `GET` or `HEAD /:id/preview`  | Available derivative, range support; never executes uploaded HTML.                                                                                          |
| `DELETE /:id`                 | Explicit permanent file deletion, including derivatives; rejected during conversion. Library references are not automatically rewritten.                    |

Uploads reserve original-byte quota before consuming the stream. Aborted uploads are cleaned up; startup removes interrupted reservations. Originals have UUID storage paths and mode `0600`; the storage directory is `0700`. Account quota covers originals, not derivative disk usage. Operators must provision additional scratch/preview storage. One gateway process owns a storage directory/database; there is no multi-host upload locking. Uploads create a new file ID each time; they are not idempotent. Use the returned hash/ID and library idempotency for reuse rather than retrying an uncertain upload blindly.

MCP provides `bridge_file_upload` (512 KiB decoded limit) and `bridge_file` (`list`, `info`, `read`, `prepare`, `formats`, `download`). Larger files use streamed HTTP or the Apple file picker. Download results contain authenticated routes, never a public URL or an embedded credential.

## Format behavior

| Types                                              | Read                                                                                  | Display/open                                                                                                                          |
| -------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| PDF                                                | Text extraction when available; scanned/encrypted PDFs may need OCR/password          | PDF original/Quick Look                                                                                                               |
| DOCX, XLSX, PPTX                                   | Bounded package text/cell/slide extraction                                            | Optional converted PDF; Apple Quick Look for original                                                                                 |
| DOC, XLS, PPT, RTF                                 | Optional Office conversion/text extraction; DOC/RTF have native textutil fallback     | Converted PDF/text when available, otherwise original Quick Look/open-with                                                            |
| Pages (+ Numbers/Keynote)                          | Embedded package preview/metadata when present; not a complete iWork semantic decoder | Embedded preview or native Quick Look/open-with; some packages require the original app                                               |
| TXT, CSV, JSON, XML, HTML/HTM                      | Bounded UTF-8 source, pretty JSON when valid                                          | Escaped/plain text; scripts, remote HTML resources and XML entities are not run                                                       |
| JPG/JPEG, PNG, GIF, WebP, HEIC, SVG, TIFF/TIF, BMP | Dimensions/frame metadata where available; no OCR promised                            | Bounded PNG thumbnail; original remains downloadable. GIF derivative is first frame; original preserves animation. SVG is rasterized. |
| MP4, MOV, AVI, MKV, WebM, WMV                      | Codec/duration/media metadata; no speech transcription promised                       | H.264/AAC MP4 derivative when codecs are available                                                                                    |
| MP3, WAV, M4A, AAC, FLAC                           | Codec/duration metadata                                                               | AAC/M4A derivative when codecs are available                                                                                          |
| ZIP, RAR, 7z, TAR, GZ                              | Bounded member list or gzip decompressed prefix                                       | Text listing; never automatically extract or execute entries                                                                          |
| Any other extension                                | Name, bytes, hash and metadata                                                        | Original upload/store/download; native open-with if a compatible application exists                                                   |

Text extraction targets a bounded 1 MiB read (Unicode conversion may change encoded size); the Apple screen/Read File intent shows at most 20,000 characters. Archive safeguards limit member count, expanded sizes and compression ratios. Media derivatives cover at most the first 600 seconds; full originals remain intact. Corrupt, password-protected, DRM-protected or unsupported codecs return explicit unavailable/partial results. Extension recognition does not override decoder failure.

## Apple interface

The primary app and Messages extension include a File library: enter an exact chat ID, load, import using the system picker, prepare, view text, open original/preview, save or open with another app. Downloads use the paired agent credential and private protected temporary files. Quick Look decides whether it can render each original. Closing the preview removes that temporary copy.

A library chat ID is a server authorization scope, **not** proof that the currently visible `MSConversation` is that chat. The library does not silently send downloads into an arbitrary current conversation. Developers use an explicit user-facing attachment action through `ConversationPort` after resolving their own conversation-binding policy. Apple participant UUIDs do not expose the native gateway chat ID.

## Evidence

[FILE_ACCEPTANCE.json](FILE_ACCEPTANCE.json) records actual synthetic upload/download hashes, converter status and warnings per extension. These tests do not prove recipient-side iMessage rendering, physical-phone Quick Look compatibility, or all codec variants. The 2026-10-07 matrix includes a genuine Pages document generated in Pages and a small RAR fixture from the libarchive project. All 41 listed extensions preserved their originals and produced local derivatives/listings. This is sample-level coverage, not a guarantee for every version, codec or encrypted file.

To reproduce the standard synthetic fixtures, run `python3 scripts/generate-file-fixtures.py` (Pillow, openpyxl, python-pptx and the configured native converters required), then `node --import tsx scripts/file-acceptance.ts`. The latter uses a fixture-only gateway, downloads originals and derivatives, and records HTTP status, byte count and format signatures. It never connects to Messages. The additional Pages sample was created as a new synthetic document in Apple Pages; the RAR sample comes from [libarchive's test fixture](https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar.rar.uu). Keep fixture files under ignored `work/file-fixtures`; do not use personal files. The generator creates 39 formats; Pages and RAR require those separately sourced fixtures to reproduce the full 41-format run.
