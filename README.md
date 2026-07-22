# wCopy NFC for Mac

English | [中文](README_zh.md)

A native macOS GUI tool for the wCopy / NSR106-IDIC V USB NFC reader. Built from the
USB-HID and PN532 encapsulation protocol reverse-engineered by
[`mariogiordano96/wcopy-nfc-linux`](https://github.com/mariogiordano96/wcopy-nfc-linux),
using IOKit directly on macOS — no kernel driver, `hidraw`, GTK, or Python runtime required.

The app supports both **English and Chinese**, detecting the system language automatically.

## Device Support

| VID:PID | Status |
| --- | --- |
| `0416:b008` | HID sequence sync and init handshake verified on `wCopy NSR106-IDIC V601` hardware |
| `0416:b030` | Validated by upstream on real Linux hardware; same protocol, native macOS implementation |

USB enumeration and protocol compatibility are displayed separately. A detected device does
not mean the protocol is ready — only after serial number sync and the four‑step
initialization will the status report "Protocol Ready". If `b008` syncing fails, the app
preserves diagnostic info rather than reporting a false connection.

## Features

- Auto‑discovers the 64‑byte HID interfaces of `0416:b008` and `0416:b030`.
- MIFARE Classic Mini, 1K, 4K card identification, showing UID, ATQA, SAK.
- Supports Classic 2K geometry as well as the hardware‑verified
  `SAK 19 + ATQA 0004 + 4‑byte UID` Classic 1K compatible profile.
- Key A / Key B and sector range selection for reading, with progress and cancellation.
- Per‑sector Key A / Key B checks using tiered built‑in dictionaries or custom wordlists.
- Import `.dic`, `.keys`, `.txt`; load Proxmark3 / MCT community dictionaries online;
  auto‑parse comments, deduplicate, and count invalid lines.
- JSON dumps compatible with upstream format, extended to save card type, ATQA, SAK,
  and known per‑sector keys.
- Standard `.mfd` (320 / 1024 / 2048 / 4096 bytes) import and export.
- Safe restore: skips block 0 and sector trailers by default, with optional write‑back
  verification.
- Magic / CUID card 4‑byte UID modification; auto‑computes BCC and performs full read‑back
  verification.
- Format specified sectors while preserving manufacturer block 0.
- Native raw PTY bridge for running `nfc-list`, `mfoc`, `mfcuk`.
- HID descriptor, handshake, log, and raw PN532 command diagnostics.
- Agent‑friendly `wcopy-nfc` CLI with stable JSON output, exit codes, read‑only /
  write safety boundaries, and no‑interaction parameters.
- **Bilingual UI**: auto‑detects system language (English / Chinese) and switches all
  interface text accordingly.

125 kHz ID cards are not supported. Upstream captures only show the poll command `0x65`
with no successful card‑read response, so reliable functionality cannot be implemented.
UFUID permanent locking is also not implemented — no verifiable chip‑specific commands
exist and the operation is irreversible.

## Build

Requires macOS 13 or later and Xcode Command Line Tools / Swift 6.

```bash
swift build
swift test
swift run WCopyNFCMac
```

Build a double‑clickable app bundle:

```bash
./Scripts/build-app.sh
open "dist/wCopy NFC.app"
```

The script builds a native release for the host architecture with ad‑hoc signing by default.
For a universal binary spanning the current toolchain:

```bash
ARCHS="arm64 x86_64" ./Scripts/build-app.sh
```

Build outputs:

- `dist/wCopy NFC.app` — the GUI application.
- `dist/wcopy-nfc` — the CLI, callable directly from terminal, scripts, or agents.

The CLI can also be launched from a SwiftPM development build:

```bash
swift run WCopyNFCMac cli devices --pretty
swift run WCopyNFCMac cli capabilities --pretty
```

Release CLI examples:

```bash
./dist/wcopy-nfc devices --pretty
./dist/wcopy-nfc reader-info --pretty
./dist/wcopy-nfc card-info --card-mode auto --pretty
./dist/wcopy-nfc keys --preset quick --card-mode 1k --pretty
```

See [`docs/CLI.md`](docs/CLI.md) for the full command set, JSON schema, exit codes,
safety rules, and agent workflows.

macOS's IOKit HID manager generally does not require Linux‑style udev rules. If the
device fails to open, close the official software or any other app that might be holding
the same HID interface, then re‑plug the reader.

## First Use

1. Insert the NSR106-IDIC V, open the app, and click the toolbar refresh button.
2. Select `0416:B008` and click "Connect". The first sync may take up to ~30 seconds.
3. Once "Protocol Ready" appears, place a 13.56 MHz MIFARE Classic card on the reader.
4. Go to "Read & Backup" and save a JSON dump. Note that MIFARE hardware hides Key A
   in the trailer blocks; you need a key‑check pass to obtain full A/B keys before
   safely exporting a complete MFD or restoring trailer blocks.
5. If authentication fails, use "Key Check"; for unknown keys, use the `mfoc` bridge.

## Default Key Dictionaries

The "default key check" is not a brute‑force scan of the full 48‑bit key space. The app
only tries a user‑selected candidate set:

- Quick defaults: 13 high‑hit defaults matching the `mfoc` default set.
- Common public keys: an independently curated list of common defaults, test values,
  and publicly deployed keys.
- Weak‑mode extension: extends the common set with repeat‑byte, sequential‑increment,
  and sequential‑decrement patterns.
- Custom wordlists: supports Proxmark3 `.dic`, MIFARE Classic Tool `.keys`, and plain text.

The app provides one‑click entries for the Proxmark3 and MIFARE Classic Tool community
dictionaries. Downloaded content is used at runtime only, is not redistributed with this
project, and its GPL‑licensed origin is noted in the UI. Large dictionaries may trigger
tens of thousands of authentication attempts; duration depends on dictionary size, card
type, and USB response speed. Keep the card stationary during the check.

Scanning is ordered by candidate hit probability: the app tries one candidate against all
missing sector key slots before moving to the next candidate. After an authentication
failure the app re‑selects and verifies the same UID to prevent residual failure state
from affecting subsequent candidates. If the access bits configure a Key B slot as readable
data, the result shows `DATA`; the value can be used for a full backup, but per the NXP
spec it cannot be used for Key B authentication. Sector key cells support copy, and
pasting a 6‑byte key from the clipboard; pasted values are only saved after actual
authentication against the corresponding sector. Key B slots marked `DATA` cannot accept
a pasted authentication key.

### Non‑Standard SAK and Forced Card Modes

The standard SAK table does not cover all compatible chips. Based on hardware testing,
cards that simultaneously report `SAK 0x19`, `ATQA 0x0004`, and a 4‑byte UID are
automatically treated as SAK‑19‑compatible Classic 1K (16 sectors, 64 blocks). The card
type menu offers:

- Auto (includes SAK 19)
- SAK 19 Compatible Classic 1K
- Force Classic Mini
- Force Classic 1K
- Force Classic 2K
- Force Classic 4K

When key‑check identifies an SAK 19 compatible card it generates candidates from the
4‑byte UID:

```text
Key[0] = UID[0] XOR UID[1]
Key[1…4] = UID[0…3]
Key[5] = UID[2] XOR UID[3]
```

For example, synthetic UID `12345678` produces `26123456782E`. In the compatible layout
this candidate may apply to sectors 1/15, but the app still performs real authentication
against the card — it never marks a hit or fills other sectors based solely on the formula.

Forced modes only change the sector/block geometry that the software uses; they do not
modify the card's SAK, ATQA, UID, or any data. Selecting a mode that exceeds the real
capacity will only cause authentication failures on higher sectors. For cards matching
the tested combination, use Auto or the SAK 19 Compatible entry from the list — don't
blind‑scan as 2K/4K.

The card type mode carries through to read, default key‑check, dump restore, and format
operations. If you force‑read as 2K and produce a 2048‑byte MFD, you must also select
"Force Classic 2K" when restoring to a similar non‑standard card; otherwise the app
enforces safety checks based on auto‑detected capacity and rejects out‑of‑bounds restores.

`SAK 0x19` is not an NXP standard card type value and does not by itself identify a chip
vendor. The current compatibility rules come from physical reading results: verified
`ATQA 0004 / SAK 19 / 4‑byte UID` compatible cards can read blocks 0–63 (64 blocks);
some also exhibit compatible behaviour where Key B authentication takes precedence over a
static interpretation of the access bits. Other combinations are not asserted as a
specific vendor or chip model based solely on SAK.

Public default keys can only discover static defaults or weak passwords. Truly random,
UID‑derived, or unknown keys require authorized `mfoc`/`mfcuk` nested or DarkSide
workflows; feasibility depends on the card's PRNG and the reader firmware capability.

The device protocol is sensitive to error sequences. If HID is detected but syncing fails,
unplug the reader for a few seconds and reconnect. Do not move the card or unplug the
reader during write or format operations.

## Optional libnfc Tools

```bash
brew install libnfc mfoc mfcuk
```

When the GUI starts a bridge command, it first releases its HID connection and launches the
same CLI bridge path used by `dist/wcopy-nfc`. The child process creates a fresh transport,
synchronizes and initializes the reader, creates the PTY, and sets
`LIBNFC_DEFAULT_DEVICE=pn532_uart:<pty>`. Reconnect in the GUI after the command finishes.
The GUI batches bridge output and omits high-frequency frame previews so long mfoc recovery
runs do not block the interface; key results, progress, warnings, and errors remain visible.
Upstream has verified `nfc-list` and the `mfoc` default‑key dictionary phase; true
nested / DarkSide attacks have not yet been tested on this hardware.

For `SAK 19 + ATQA 0004 + 4‑byte UID` cards, the bridge remaps the SAK in the
anti‑collision response to the standard 1K value `08` only when communicating with
old libnfc tools that don't recognise SAK 19. In‑app records and the physical card
always keep the original `19`.

## B008 Diagnostics

`0416:b008` (`wCopy NSR106-IDIC V601`) handshake has been verified on hardware via this
project's CLI. If a different firmware fails to connect:

1. Re‑plug the device and retry once, in case the device sequence counter is in an
   abnormal position.
2. Open "Diagnostics" and confirm both HID input and output reports are at least 64 bytes.
3. Click "Export Diagnostics" to save the text output.
4. Provide the `ioreg -p IOUSB -l -w 0` output along with the diagnostic text so that
   `b008` and `b030` interface descriptors can be compared.

## Security & Authorization

Only operate on cards you own or have explicit authorization for. Writing UIDs,
restoring trailer blocks, and formatting can destroy data; restoring incorrect
access bits may permanently lock sectors. The app defaults to conservative write
policies, but it cannot eliminate the risks of hardware disconnection, card movement,
or incorrect dumps.

## Credits & License

USB‑HID framing, checksums, startup sequence, and PN532 encapsulation are based on
Mario Giordano's `wcopy-nfc-linux` (MIT License). Full upstream license details are
in `THIRD_PARTY_NOTICES.md`.

This project is also released under the MIT License — see `LICENSE`.
