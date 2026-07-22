# AGENTS.md

This file defines the working requirements for coding agents in this repository.
It applies to the entire project unless a more specific `AGENTS.md` exists in a
subdirectory.

## Project Overview

`wcopy-nfc-mac` is a native macOS application and CLI for wCopy / NSR106-IDIC V
USB NFC readers. It reimplements the USB HID wrapper and PN532 protocol used by
the reader without Python, GTK, `hidraw`, or a kernel driver.

Primary targets:

- macOS 13 or newer.
- Swift Package Manager with Swift 6 tools and Swift 5 language mode.
- USB HID devices `0416:B008` and `0416:B030`.
- MIFARE Classic Mini, 1K, 2K, and 4K geometries.
- The verified `ATQA 0004 / SAK 19 / 4-byte UID` Classic 1K-compatible card.
- A SwiftUI application and the JSON-oriented `wcopy-nfc` CLI.

Only operate on cards owned by the user or explicitly authorized for testing.

## Repository Layout

- `Sources/WCopyNFCMac/main.swift`: GUI/CLI entry-point selection and signals.
- `Sources/WCopyNFCMac/AppModel.swift`: SwiftUI state and serialized operations.
- `Sources/WCopyNFCMac/Views.swift`: SwiftUI pages and controls.
- `Sources/WCopyNFCMac/HIDTransport.swift`: IOKit HID discovery and transport.
- `Sources/WCopyNFCMac/WCopyReader.swift`: wCopy framing, PN532, MIFARE, read,
  key checking, restore, UID, format, and mfoc recovery orchestration.
- `Sources/WCopyNFCMac/LibNFCBridge.swift`: PTY-based PN532 UART bridge for
  libnfc tools.
- `Sources/WCopyNFCMac/Models.swift`: card geometry, dumps, keys, errors, and
  shared data types.
- `Sources/WCopyNFCMac/KeyDictionary.swift`: built-in and imported key sets.
- `Sources/WCopyNFCMac/CLI.swift`: CLI parsing, JSON schema, commands, and exits.
- `Tests/WCopyNFCMacTests/ProtocolTests.swift`: protocol and model unit tests.
- `Scripts/build-app.sh`: signed Release App Bundle and CLI build.
- `docs/CLI.md`: public CLI contract and agent usage rules.

## Required Verification

Use the smallest relevant verification first:

```bash
swift build
swift test
```

For changes affecting the distributed application or CLI, also run:

```bash
./Scripts/build-app.sh
codesign --verify --deep --strict "dist/wCopy NFC.app"
codesign --verify --strict "dist/wcopy-nfc"
```

Important: `swift build` only updates `.build`; it does not update the app the
user launches from `dist/wCopy NFC.app`. Any UI or Release validation must run
`./Scripts/build-app.sh`, completely quit the old app process, and reopen the
new bundle.

Development entry points:

```bash
swift run WCopyNFCMac
swift run WCopyNFCMac cli devices --pretty
```

Release entry points:

```bash
open "dist/wCopy NFC.app"
./dist/wcopy-nfc devices --pretty
```

## Coding Requirements

- Prefer the smallest correct change and preserve the existing architecture.
- Use Foundation, SwiftUI, IOKit, and Darwin APIs already used by the project.
- Do not add a runtime dependency on Python, GTK, Linux `hidraw`, or a custom
  kernel driver.
- Keep hardware access serialized through `AppModel.operationQueue` or one CLI
  reader session. Never access the same HID interface concurrently.
- Keep cancellation checks in long read, dictionary, bridge, and write loops.
- Keep protocol logs out of CLI stdout. CLI stdout must remain one JSON document
  for all non-help commands; verbose logs go to stderr.
- Preserve uppercase, separator-free hexadecimal values in stored and machine
  output unless a diagnostic field explicitly documents another format.
- Validate all keys as exactly 6 bytes, blocks as exactly 16 bytes, and UIDs as
  the supported length before sending hardware commands.
- Do not silently convert a transport/protocol error into an authentication
  miss unless the PN532 status is known to mean authentication failure.
- Add tests for pure framing, parsing, geometry, dump, or compatibility logic.
  Hardware tests must not be placed in the normal unit-test suite.
- Do not edit generated `.build` or `dist` binary contents manually.

## HID and PN532 Invariants

- HID reports are 64 bytes.
- Outbound wCopy reports start with `0x01`; inbound reports start with `0x02`.
- A successful exchange consumes two sequence values. Preserve sequence
  synchronization and expected-response checks.
- B008 synchronization is runtime behavior, not guaranteed by USB enumeration.
- `devices` only proves discovery. A successful sync and four-step initialize
  sequence proves protocol readiness.
- Failed MIFARE authentication may leave the card/PN532 session unusable until
  it is reselected. Keep `reselect` behavior after expected authentication
  failures.
- Preserve the CLI allow-list for raw PN532 commands. Do not expose arbitrary
  write commands through diagnostics.

## SAK 19 Compatibility

Treat a card as the custom Classic 1K-compatible type only when all conditions
match:

- SAK is `0x19`.
- ATQA is `0x0004`.
- UID length is 4 bytes.

This compatibility type has 16 sectors and 64 blocks. Do not infer a vendor or
chip model from SAK `0x19` alone.

The UID-derived candidate is:

```text
UID[0] XOR UID[1], UID[0], UID[1], UID[2], UID[3], UID[2] XOR UID[3]
```

Always authenticate a derived candidate against the card before recording it.

Legacy libnfc tools do not recognize SAK `0x19`. `LibNFCBridge` may normalize
only a matching `D5 4B` target response from SAK `19` to `08`. Never modify the
physical card, internal `CardTarget`, JSON metadata, or unrelated target
responses as part of this compatibility mapping.

## Key Discovery and mfoc Recovery

Dictionary checking and cryptographic recovery are different operations:

1. Check selected dictionary candidates against unresolved Key A/Key B slots.
2. Return and display the dictionary result without starting mfoc automatically.
3. In the GUI, if slots remain unresolved, show the recovery prompt. Confirming
   it navigates to the mfoc page; the user starts recovery manually there.
4. After manual recovery succeeds, parse the produced MFD, merge only previously
   missing keys, and retain the card geometry expected by the detected target.

For the verified SAK 19 card with UID `48C8403C`, the working bridge command is
equivalent to:

```bash
mfoc -k A0A1A2A3A4A5 -O /absolute/path/to/output.mfd
```

The recovery UI must preserve these constraints:

- Pass one known authenticating seed key, preferably the first known Key A in
  sector order. Do not pass every discovered key to mfoc.
- Additionally pass any non-quick dictionary keys discovered during the scan
  (e.g., UID-derived keys for SAK 19 cards) so that mfoc can authenticate all
  sectors during the dictionary phase and skip the attack-phase transition
  that may fail the same `select_passive_target` call.
- Do not add `-P 500`. The verified flow uses mfoc defaults.
- Use a unique absolute temporary MFD path, not a relative `dump.mfd`.
- Run mfoc through `LibNFCBridge`; do not let libnfc open the wCopy HID device
  directly.
- Start the bridge with a freshly synchronized and initialized reader session
  when invoked from the recovery page.
- Do not start mfoc inside dictionary checking. Preserve the explicit prompt,
  navigation, and manual start boundary between both operations.
- On successful exit, parse and import the MFD automatically, then delete the
  temporary file.
- On nonzero exit, preserve the log, delete the partial MFD, and do not import.

Passing all known keys is not an optimization. mfoc tests each custom key across
many sector/key slots; irrelevant keys create avoidable failed authentications.
On this reader, some failed PN532 MIFARE commands can produce no reply instead
of a normal authentication-failure status, causing libnfc to report `Timeout`,
`Unexpected PN53x reply`, or `Tag has been removed` even when the card remains
physically present.

When diagnosing mfoc behavior, compare the exact command printed after
`libnfc bridge started`. If it contains multiple `-k` arguments, `-P 500`, or a
relative `-O dump.mfd`, an old App Bundle is running or the verified flow has
regressed.

mfoc/libnfc are optional runtime tools and may be installed with:

```bash
brew install libnfc mfoc
```

Do not vendor GPL key dictionaries or mfoc source into this MIT repository
without an explicit licensing decision.

## Dumps and Card Geometry

- JSON is the metadata-rich project format.
- MFD sizes are exactly 320, 1024, 2048, or 4096 bytes.
- A 1K-compatible card result must expose exactly blocks `0...63`, even if an
  external MFD parser inferred a larger geometry from malformed/padded output.
- MIFARE hardware hides Key A on normal trailer reads. A complete MFD export
  requires known Key A and Key B values for every trailer.
- `keyBAuthenticates == false` means the trailer Key B field is readable data,
  not a valid Key B authentication credential.
- Do not replace a known key with `000000000000` or another placeholder parsed
  from an incomplete external dump.

## Write Safety

Writing commands require explicit user confirmation and conservative defaults:

- Skip block 0 unless explicitly requested for a compatible Magic/CUID card.
- Skip sector trailers unless explicitly requested.
- Verify writes by reading back whenever possible.
- Authenticate every target sector before beginning a multi-block mutation.
- If a write has been attempted and an error occurs, report `MutationError`
  with attempted and acknowledged blocks. Do not automatically retry.
- Never weaken the CLI `--yes` confirmation requirement.
- Never claim that `--yes` makes UID, trailer, restore, or format operations
  physically safe.

## CLI Contract

Treat `docs/CLI.md` as the authoritative public contract.

- Exit `0`: complete success.
- Exit `10`: valid partial result or verification miss; still parse JSON data.
- Exit `130`: cancelled.
- Other documented nonzero exits are failures.
- Keep `schemaVersion` stable unless intentionally making a contract change.
- Update `capabilities`, command help, `docs/CLI.md`, and tests together when
  adding or changing a CLI command or option.
- Mutating commands must remain clearly marked in capabilities.

## Hardware Test Procedure

Before a live hardware test:

1. Confirm only one of the GUI, CLI, official software, or another NFC tool is
   using the reader.
2. Run `devices`, then `reader-info` or connect in the GUI.
3. Keep one card stationary in the RF field.
4. Start with read-only detection or key verification.
5. Use a generous external timeout only for read-only dictionary/mfoc work.
6. Never externally kill, unplug, or move the card during a write operation.

Do not interpret a libnfc `Tag has been removed` message literally without
examining preceding PN532 traffic. It can be a failed authentication timeout on
this bridge, not physical card removal.

## Documentation Updates

Update both `README.md` and `README_zh.md` when changing user-visible features.
Update `docs/CLI.md` for CLI behavior, output fields, safety rules, or examples.
Document only behavior verified by tests or hardware logs; clearly label
upstream-only or unverified hardware support.
