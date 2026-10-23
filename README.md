# SSCOM for macOS

A native macOS (Apple silicon, macOS 27) port of **SSCOM 5.13.1**, the serial / TCP / UDP debugging terminal.
Written in Swift 6 language mode with Swift 6.2 concurrency settings (MainActor-by-default, approachable concurrency),
SwiftUI for the interface and AppKit where it matters (the high-volume receive view and terminal key handling).

## Build

```sh
./build.sh                         # xcodegen → unit tests → Release archive → Developer ID export to ./dist
NOTARY_PROFILE=myprofile ./build.sh  # also notarize + staple (profile from `xcrun notarytool store-credentials`)
```

Or `xcodegen generate` and open `SSCOM.xcodeproj`. Signing uses the *Developer ID Application* identity of
team `49G92DYD5H` from the login keychain. Requirements: Xcode 27, XcodeGen.

`SSCOMKit/` is a Swift package with all protocol logic, transports and flashers. Run `swift test` inside it (28 tests,
including real TCP/UDP/serial I/O and simulated STM32 and STC bootloaders).

## Feature parity with SSCOM 5.13.1

| SSCOM feature | macOS port |
|---|---|
| Serial port, custom baud 110 bps – 50 Mbps, data/stop/parity/flow | ✅ POSIX termios + `IOSSIOSPEED`; ports listed via IOKit with USB product names |
| USB adapter unplug auto-repair | ✅ IOKit hot-plug notifications reopen the port when it returns |
| DTR / RTS outputs, CTS/DSR/DCD/RI indicators | ✅ |
| TCP client, TCP server (multi-client), UDP, host names | ✅ Network.framework (TCP), BSD socket (UDP) |
| String / HEX send, escapes `\x?? \\ \r \n \t \v \a \b \f \0`, add CR LF | ✅ |
| Timed send | ✅ |
| Checksums: ModbusCRC16, CCITT-CRC16, CRC32, 0-ADD8, ADD8, XOR8, ADD16, header/tail ranges | ✅ byte-exact with the original (verified from the decompiled routine) |
| 99 user strings, notes, loop order + delay, import `sscom51.ini` | ✅ (the ini importer reads existing GBK files) |
| HEX display, “time and packet” display with TX / RX markers (Windows used `◇ □ ◆`, which macOS fonts lack) and packet timeout | ✅ and switching modes no longer loses timestamps |
| Display buffer limit (200 KB – 5 MB, keep newest 100 KB) | ✅ |
| Send file with 0/1/10/50/100 ms per 256 bytes, stop | ✅ |
| Save window + raw data, receive to file | ✅ (via save panels, as the sandbox requires) |
| Terminal emulation (key mode / line mode, local echo, CR→CRLF, Ctrl+Z) | ✅ type straight into the receive window; paste sends |
| Font, colors, always on top, open at startup | ✅ |
| Data waveform (single channel, 8-bit, signed/unsigned, ‹500 / 500›, live) | ✅ Swift Charts |
| STM32 / GD32 ISP | ✅ AN3155 bootloader; DTR/RTS reset & BOOT0 control with polarity options; timeouts (the original waited forever) |
| STC / IAP15 ISP | ✅ same frames and sequence as SSCOM (recovered from the binary) |
| English / Chinese UI | ✅ English + Simplified Chinese (`Localizable.xcstrings`) |
| Text encoding | ➕ UTF-8, GB18030/GBK or Latin-1 for sent and received text |

Not ported on purpose: the startup version check and news feed (the daxia.com server), the JLC PCB
advertising panels, and the disabled “conversion calculator” and “LUA script” menu items, which did nothing in
5.13.1. Mark/space parity and 1.5 stop bits aren't offered because macOS serial drivers don't support them.

## Hardware notes

The ISP flashers are tested against simulated bootloaders and the protocol bytes were checked against
SSCOM's decompiled code. They haven't been run against real chips from this Mac yet, so try them on a
development board first.
