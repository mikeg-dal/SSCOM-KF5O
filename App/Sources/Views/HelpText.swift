import Foundation

/// Help content, condensed from SSCOM 5.13.1's built-in help.
enum HelpText {
    static let checksum = String(localized: """
        Adding a checksum to sent data

        The checksum tool sends frames shaped “header + data + checksum + tail”.

        1. “Checksum from byte”: the first byte included in the checksum. Enter 1 to check the whole frame. With a 1-byte header enter 2, with a 2-byte header enter 3, and so on.
        2. “to”: choose End if the frame has no tail. With a 1-byte tail choose −1, with 2 bytes −2, and so on. The tail is not checked.
        3. Choose the algorithm: ModbusCRC16, CCITT-CRC16, CRC32, 0-ADD8, ADD8, XOR8 or ADD16. None adds nothing.
        4. The checksum bytes are inserted in front of the tail. After sending, the value is shown next to the algorithm.
        5. If the header and tail settings leave 0 bytes to check, no checksum is added.
        6. It applies to the main send box and to all 99 strings. In string mode the CR LF added by “Add CR LF” is part of the checksum.

        Byte order: ModbusCRC16, CCITT-CRC16 (XMODEM, init 0) and CRC32 are sent low byte first; ADD16 is sent high byte first; 0-ADD8 is the two's complement of the 8-bit sum.

        Example: header AA 55, data 06 FF 00 30 88 99 AB, XOR8, tail EE.
          ① Enter the frame including header and tail: AA 55 06 FF 00 30 88 99 AB EE
          ② Checksum from byte 3
          ③ to −1
          ④ XOR8
          ⑤ Send. The frame sent is AA 55 06 FF 00 30 88 99 AB 73 EE (73 is the checksum).
        """)

    static let presets = String(localized: """
        User-defined strings

        1. Tick HEX for a hexadecimal string, written like “13 00 FF” (three bytes).
        2. Type the data to send in the text field.
        3. Double-click the send button (or right-click it) to give the string a note. The note is shown on the button.
        4. Click the button to send the string immediately.
        5. “Loop send” sends every string whose order number is above 0, from the lowest order number to the highest. Equal numbers are sent top to bottom. After each string the app waits that string's delay. The string being sent is highlighted in red.
        6. “Add CR LF” and the checksum settings from the main panel also apply here.
        7. “Import ini…” loads the strings and settings from an SSCOM sscom51.ini file.
        """)

    static let stm32 = String(localized: """
        STM32 / GD32 ISP download

        Uses the chip's built-in USART bootloader (ST AN3155) on USART1 (PA9/PA10). The whole flash is mass-erased, then the HEX file is written and started.

        One-click download: wire DTR and RTS to the MCU's RESET and BOOT0 pins (through the usual transistor circuit) and choose the matching Auto setting. If your board resets or does not enter the bootloader, try the Invert options.

        Manual download: set BOOT0 = 1 and reset the MCU so it waits in ISP mode, then click Start Download.

        This tool does not check that the image fits the chip's flash. Use the slower speed for built-in serial ports, and the faster one for USB adapters such as the CH340.
        """)

    static let stc = String(localized: """
        STC / IAP15 ISP download

        1. Use STC's own tool once to set the MCU to run from an external crystal, and fit the crystal and load capacitors. Programming is unreliable on the internal oscillator.
        2. Open the HEX file.
        3. Click Start Download.
        4. Power-cycle the MCU (cold start).
        5. Wait for the download to finish. The MCU then runs the user program.

        This tool only programs flash. It can't change STC option settings such as the internal oscillator frequency.

        If it can't program:
        • Is the PC's TXD line powering the MCU through its high level? Add a series diode.
        • Is another I/O pin feeding power to the MCU, so it never fully powers off?
        • If the board is powered from the USB adapter, the adapter may briefly disappear at power-on. Don't share the adapter's supply.
        """)

    static let general = String(localized: """
        Using SSCOM

        Serial port: pick the port and baud rate in the panel. Data bits, stop bits, parity and flow control are under More…. Type any custom baud rate (110 bps to 50 Mbps) in the baud field and press Return. USB adapters that are unplugged by accident reconnect automatically when plugged back in.

        Network: choose TCP Client, TCP Server or UDP, then set the IP addresses and ports. A host name can be used instead of an IP address. A TCP server sends to every connected client.

        Sending strings: type in the send box and click Send, or press ⌘↩. String mode supports the escapes \\x??, \\\\, \\r, \\n, \\t, \\v, \\a, \\b, \\f and \\0. “Add CR LF” appends a carriage return and line feed (string mode only).

        Sending HEX: tick HEX send and enter bytes like “12 00 FF 80”. Invalid input stops the send. Timed send repeats the send box at the chosen interval.

        Show time and packets: received data that arrives within the timeout of the previous data joins the same packet. Each packet is shown on its own line with a timestamp. TX marks sent data and RX marks received data. In text mode, control bytes show as hex in angle brackets, such as <01>:
          [09:30:38.094] TX help
          [09:30:38.172] RX Welcome to you!
        HEX display and the timestamps can be switched at any time. The window is re-drawn from the stored traffic, so nothing is lost.

        Terminal emulation: click in the receive window and type. Each key is sent as it is pressed. Alternatively, choose to send a whole line on Return; that mode echoes your typing locally. ⌃Z sends 0x1A. Pasting sends the clipboard.

        Sending files: choose a file and click Send File. Stop interrupts it. The delay after every 256 bytes is set in the Send menu, so slow receivers can keep up.

        DTR / RTS: ticked means asserted. On USB-serial chips such as the CH340 an asserted pin is low; on RS-232 it is about +9 to +12 V. Some devices only send data when DTR is asserted.

        Saving: Save Data writes the window text and the raw received bytes to two files. Receive to file saves every received byte to a file; its size is limited only by disk space.

        Display buffer: when the window passes the limit set in the View menu, older data is dropped and the newest 100 KB is kept. For long captures, use Receive to file.
        """)
}
