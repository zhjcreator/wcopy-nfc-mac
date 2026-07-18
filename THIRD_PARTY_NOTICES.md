# Third-party notices

The USB-HID framing, checksum, synchronization sequence, initialization
commands, and PN532 bridge behavior in this project are based on:

- Project: `wcopy-nfc-linux`
- Author: Mario Giordano
- Source: https://github.com/mariogiordano96/wcopy-nfc-linux
- License: MIT

The upstream license follows.

```text
MIT License

Copyright (c) 2026 Mario Giordano

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Optional runtime dictionaries

The application can optionally download and parse key dictionaries at runtime
from the following projects. These dictionary files are not bundled with or
copied into this project. Users who load them should refer to the source
project's license and notices.

- Proxmark3 `mfc_default_keys.dic`: https://github.com/RfidResearchGroup/proxmark3
- MIFARE Classic Tool `extended-std.keys`: https://github.com/ikarus23/MifareClassicTool

The compact built-in presets are independently curated from publicly known
MIFARE defaults, test patterns, and generated weak patterns. The 13-key quick
preset is interoperable with the default values conventionally tried by mfoc.
