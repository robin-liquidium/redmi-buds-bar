# REDMI Buds 8 Pro — macOS control findings

Verified on 9 September 2026 with the user's Chinese-market REDMI Buds 8 Pro, already paired and connected to this Mac.

## Result

Direct noise control works over Bluetooth Classic RFCOMM. No phone bridge, BLE discovery, firmware modification, Xiaomi account, or app-layer authentication handshake was needed for this paired connection. This does not imply an unpaired connection is permitted.

The native app's three mode buttons were also tested by the user, who confirmed that the audible modes change correctly.

| Item | Observed value |
|---|---|
| Service | MIWEAR |
| Service UUID | `0000FD2D-0000-1000-8000-00805F9B34FB` |
| RFCOMM channel | 28, resolved through SDP |
| Vendor / product | `0x2717 / 0x50E3` |
| Firmware | `1.2.3.6` |
| OS string | `vela os earbuds` |
| Original noise setting | ANC, strength byte `0x13` (19) |
| Battery | Separate left/right values, case `0xFF` = unavailable |

Channel 6 reported for some older models is incorrect for this pair. Always discover the service and channel. The matching BudsLink profile filename is RedmiBuds8Pro.js, but its display name says Redmi Buds 6 Pro, so its unverified feature details were not blindly adopted.

## Packet layout

All multi-byte lengths and IDs below are big endian.

```text
Request:  FE DC BA C0 opcode lenHi lenLo sequence payload... EF
Response: FE DC BA 00 opcode lenHi lenLo status sequence payload... EF
Notify:   FE DC BA C7 opcode lenHi lenLo sequence payload... EF
```

The length counts only bytes between the length field and trailer. Request length includes sequence; response length includes status and sequence. Bit 7 of type identifies a request; bit 6 requests acknowledgment. A successful response status is 0.

RFCOMM callbacks can contain partial packets or several complete packets. Decoder tests cover both using actual device captures.

Notifications requesting a reply are acknowledged with the same opcode/sequence and an empty response payload. This stopped the repeated broadcasts seen with the initial read-only probe. The app queries current noise state after relevant notifications rather than letting delayed broadcasts overwrite newer state.

## Verified reads

Device information, opcode `02`, payload `FF FF FF FF`:

```text
FE DC BA C0 02 00 05 01 FF FF FF FF EF
```

Response data uses `[length, one-byte ID, value...]` records. Observed IDs: `01` firmware, `03` vendor/product, `07` battery. Firmware bytes `12 36 12 36` encode `1.2.3.6` for each side. Battery bytes `64 5F FF` mean left 100%, right 95%, case unavailable. Battery bit 7 means charging; low 7 bits mean percent. `FF` is unavailable.

Noise configuration, opcode `F3`, payload `00 0B`:

```text
TX FE DC BA C0 F3 00 03 02 00 0B EF
RX FE DC BA 00 F3 00 07 00 02 04 00 0B 01 13 EF
```

Configuration records use `[length, two-byte ID, value...]`. Noise configuration `000B` has two bytes: mode and strength. Modes: `00` off, `01` ANC, `02` transparency.

## Verified writes with independent readback

SET_CONFIG opcode `F2`, payload `[04, 00, 0B, mode, strength]`.

Transparency:

```text
TX FE DC BA C0 F2 00 06 02 04 00 0B 02 00 EF
RX FE DC BA 00 F2 00 02 00 02 EF
TX FE DC BA C0 F3 00 03 16 00 0B EF
RX FE DC BA 00 F3 00 07 00 16 04 00 0B 02 00 EF
```

Off:

```text
TX FE DC BA C0 F2 00 06 05 04 00 0B 00 00 EF
RX FE DC BA 00 F2 00 02 00 05 EF
TX FE DC BA C0 F3 00 03 19 00 0B EF
RX FE DC BA 00 F3 00 07 00 19 04 00 0B 00 00 EF
```

Restore original ANC:

```text
TX FE DC BA C0 F2 00 06 08 04 00 0B 01 13 EF
RX FE DC BA 00 F2 00 02 00 08 EF
TX FE DC BA C0 F3 00 03 1C 00 0B EF
RX FE DC BA 00 F3 00 07 00 1C 04 00 0B 01 13 EF
```

The initial sequence restored the original ANC setting. Later manual user interactions determine the current setting; app launches and reconnects do not force a mode.

## Strength controls

The ANC slider exposes 20 zero-based positions, wire values 0–19, displayed as levels 1–20. Lower, middle, and upper samples (0, 9, 19) were acknowledged and read back correctly. A boundary probe also returned 20 unchanged; that alone does not establish a distinct additional acoustic level, so the UI keeps the documented 20-position range. The precise correspondence to the official app's numbering has not been captured.

Transparency has three discrete presets, not a continuous ambient gain setting:

| Wire value | UI label |
|---|---|
| 0 | Regular |
| 1 | Voice |
| 2 | Ambient |

All three transparency values were successfully set and read back on this pair. Names follow the matching BudsLink device profile. ANC low and high plus transparency Ambient were also verified through the same BudsController used by the shipping app.

Smart ANC is config `0025`, encoded as one byte, 0 off or 1 on. The original read was `[03,00,25,00]` (off). Before an ANC slider change, the controller reads this field. If on, it sends `[03,00,25,00]` through SET_CONFIG and verifies it reads back off before writing manual strength. The smart-on-to-off branch still needs a separate live test; the already-off path was verified.

Source: [Xiaomi FAQ: smart ANC and 20 manual levels](https://www.mi.com/pk/support/faq/details/KA-666754/).

The popover sizes itself to its SwiftUI content. Sliders appear only in their corresponding active mode. During a drag the thumb moves locally, then the final value is sent and read back. Keyboard adjustments also commit. A failed change restores the displayed position to the last confirmed device value.

## Further work

Strength sliders were added after further live tests. Equalizer and gesture fields still need model-specific read/write validation. Do not infer that a generic Xiaomi profile proves every capability on this firmware.

A phone capture or official-app reverse engineering is a fallback if a future feature or firmware requires it. There is currently no need to extract the iOS application or flash the earbuds.

## Sources

- https://github.com/maniacx/BudsLink/blob/main/src/lib/devices/redmiBuds/redmiBudsSocket.js
- https://github.com/maniacx/BudsLink/blob/main/src/lib/devices/redmiBuds/deviceConfigs/RedmiBuds8Pro.js
- https://github.com/Zhaoyi-ya/TWS-Pods-PC/blob/main/xiaomi/PROTOCOL.md
- Apple's installed IOBluetooth SDK headers, especially IOBluetoothDevice and IOBluetoothRFCOMMChannel.

Research source code was read for protocol facts. Live captures and the user's audible checks establish support for this specific pair; third-party feature claims remain unverified unless listed above.
