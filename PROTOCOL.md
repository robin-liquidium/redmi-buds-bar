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

Strength sliders were added after further live tests. The model-specific gesture, EQ and feature reads below have been verified; new writes and transient sound/test tools still need manual device verification. Do not infer that a generic Xiaomi profile proves every capability on this firmware.

A phone capture or official-app reverse engineering is a fallback if a future feature or firmware requires it. There is currently no need to extract the iOS application or flash the earbuds.

## iPhone GATT findings — 8 October 2026

The same product/firmware exposes service `AF00`, characteristic `AF07` with write-without-response, and `AF08` with notifications. Initial checks on its public LE Audio endpoint used MMA type `0xC4`, replies `0x04`, without app-layer authentication. The current controller uses the private endpoint's authenticated `0xC0`/`0x00` session described below. Framing, opcodes and noise fields match the Mac implementation.

Example noise query: `FE DC BA C4 F3 00 03 01 00 0B EF`. Actual reply: `FE DC BA 04 F3 00 07 00 01 04 00 0B 01 13 EF` (ANC, strength 19).

The native iPhone implementation independently confirmed transparency, off and ANC writes with F3 readbacks, restored the initial mode/strength, and repeated the check with the Mac's Bluetooth connection restored. The Mac app resumed successful RFCOMM device-info/noise reads after removing the temporary iPhone diagnostic app. These checks establish control support with multipoint enabled; they do not establish AirPods-style automatic audio routing. Apple's CoreBluetooth GATT API is used instead of the Mac's IOBluetooth RFCOMM API.

Xiaomi's [connection FAQ](https://www.mi.com/global/support/faq/details/KA-666754/) describes a two-minute iOS advertising window after waking the earbuds. Save the discovered peripheral identity and reconnect it directly; a case wake may still be needed after a lost connection.

See [the iPhone project](iOS/README.md). Official MMA reference: [Xiaomi protocol](https://developers.xiaoai.mi.com/api/doc/render_markdown/VoiceserviceAccess/Bluetooth/BluetoothProtocol/CommunicationProtocol).

## Research sources

- https://github.com/maniacx/BudsLink/blob/main/src/lib/devices/redmiBuds/redmiBudsSocket.js
- https://github.com/maniacx/BudsLink/blob/main/src/lib/devices/redmiBuds/deviceConfigs/RedmiBuds8Pro.js
- https://github.com/Zhaoyi-ya/TWS-Pods-PC/blob/main/xiaomi/PROTOCOL.md
- Apple's installed IOBluetooth SDK headers, especially IOBluetoothDevice and IOBluetoothRFCOMMChannel.

Research source code was read for protocol facts. Live captures and the user's audible checks establish support for this specific pair; third-party feature claims remain unverified unless listed above.

### iPhone discovery and reconnection

The buds expose two AF00 endpoints. The public LE Audio advertisements include 184E and the REDMI name; this endpoint initially returned C4/04 noise commands. Its discovery window expired after pairing, and later reconnection required a 2-second case-button press. These short successful checks did not establish sustained operation.

The current iPhone implementation selects this model’s private manufacturer-advertised endpoint (stable first six bytes 8F 03 16 01 37 A0; the following status byte varies). It performs the C0/00 MMA 50/51 authentication handshake used by Xiaomi’s app. A Swift adaptation of BudsLink’s algorithm matched a complete captured official challenge/response byte for byte. It validates the peer response, sends 51 completion, answers reciprocal 50 challenges and replies [01] to successful peer 51 requests. The authentication implementation has GPL attribution and a bundled license notice. Command payloads and authentication data are not included in app diagnostics.

AF00 alone cannot select the endpoint. The controller stores an identity in the App Group only after authentication, VID/PID (2717/50E3), device info and noise reads succeed, then shares it with the controls extension. It retains verified identities through transient timeouts. A peripheral reported connected by iOS still needs the current central manager’s local connect before service access. Commands and acknowledgments queue through CoreBluetooth’s write-without-response backpressure instead of treating a full write buffer as an immediate failure.

The captured stale private BLE bond returned CBError 14, “Peer removed pairing information,” while audio remained connected. Two Redmi entries existed in iPhone settings; removing the disconnected control entry repaired that bond. Current errors distinguish this condition from discovery and command timeouts.

Authenticated reads and complete mode/cycle checks succeeded without another physical pairing step, with the Mac controller paused and again running. Holding the iPhone session prevented the Mac RFCOMM control channel opening, which motivated the idle-release change below. Global Mac Bluetooth and audio remained connected during isolation. Mode acknowledgments must still be checked against actual noise reads; the app never treats an acknowledgment alone as success.

### Idle control-channel handoff

The private BLE connection can keep MIWEAR RFCOMM from opening on the Mac even while Mac audio remains connected. Mac logs recorded repeated channel-open timeouts while the iPhone held the authenticated session. Both controllers now release their control transports after commands settle (iPhone 1 second, Mac 0.5 second), retain confirmed readings and reacquire for the next action. Neither release calls the audio device's disconnect method. CoreBluetooth ownership is tracked separately from the peripheral's system connection state. An initial authentication challenge timeout gets one delayed retry with a new nonce; authentication mismatches and setting writes are never blindly retried. Build 6 passed all direct-mode App Intents, cycling, shared icon state and original-setting restoration at 2026-10-07T22:32:34Z. iPhone diagnostics confirmed idle release at 22:32:39Z; the Mac then opened RFCOMM, read the same transparency setting and released its channel at 22:33:00Z. A fresh return-to-iPhone read passed at 22:33:09Z, followed by another successful Mac read/release at 22:33:30Z. This establishes the tested control handoff, not long-term sleep/wake reliability or AirPods-style audio routing.

### Firmware OTA

Xiaomi's official OTA specification is available at https://developers.xiaoai.mi.com/api/doc/render_markdown/VoiceserviceAccess/Bluetooth/BluetoothProtocol/OTAUpgrade . For product 2717/50E3, E1 returns identifier offset 0 and length 14. The official 1.2.3.7 header is `271750E31237002F3406C69BA29B`: firmware data length 3,093,510; CRC32 C69BA29B. The complete MMA image is 3,093,524 bytes. The official CDN download adds a 1,341-byte signing envelope after that declared image. The app validates the entire download against the official metadata MD5, then sends blocks only from the validated image.

The guest endpoint is `https://cn.tws.wear.mi.com/twswear/device/latest_ver?locale=en_US`, POST form field `data` with JSON model `miwear.headphone.p76c`, platform `android`, app_level `1.38.0`, fw_ver and channel `prod`. Xiaomi's distributed app includes an anonymous app-client header accepted by this endpoint; personal account authentication is not required. Official metadata returned version `1.2.3_0007` and checksum `8770fe49df6fa81cd993483c04708aec`. CDN file SHA-256: `112cf364f1cff4ca801996adf19f2c0445d19fd037f50c93ddea803dc47664db`.

Reassembly of the earlier Xiaomi capture yielded a complete E5 payload: 4,096 image bytes at offset 10 plus big-endian CRC32 `74ACD735`. E3 requested that offset/length with CRC enabled. E5 replied `10 00000000 0000 0032`: the TWS link between earbuds failed (0x10). Earlier E2 returned 0x12, both earbuds not in the open case; later E2 returned 3, dual-bank eligible. No completed transfer, E6 success or restart was captured.

The implementation supports this dual-bank flow only. It sends requested E5 blocks, respects requested delays and BLE write limits/backpressure, avoids inserting peer acknowledgments into fragmented frames, attempts E4 exit on interrupted transfer, verifies E6 completion and reads both earbud versions after reboot. A complete 1.2.3.6 → 1.2.3.7 physical update was verified on 8 October 2026: 756 E5 blocks all matched the official image and CRCs, E6 returned 00, reboot 03/00 was acknowledged, and both versions were independently read as 1.2.3.7 at 05:08:49Z. The restart took ~80 seconds after E6, exceeding the initial three-attempt window. Build 10 waits up to two minutes (plus any in-flight request timeout) and reconciles later readback in the firmware view. Interrupted transfer cancellation/recovery remains specified and implemented but has not been physically exercised.


### macOS firmware updater

The Mac app now shares the official discovery/download service and validated MMA image parser with iOS. Its explicit Earbud firmware window runs the E1/E2/E3/E5/E6/03 dual-bank flow over Classic RFCOMM. Large frames are split at the negotiated RFCOMM MTU using asynchronous write-completion callbacks; complete frames are queued in order so peer acknowledgments cannot interrupt a fragmented E5 frame. Ordinary polling and setting writes pause during firmware operations. The app attempts E4 exit after an interrupted transfer, keeps the task alive when the window closes, prevents normal quit/idle system sleep and checks both versions for up to two minutes after reboot.

On 8 October 2026, the Mac read both versions as 1.2.3.7, discovered and validated the official 3,093,524-byte image, and issued read-only E1/E2 queries. E2 rejected readiness with 0x12 (buds must be in the open charging case), as expected for that device state. No E3 entry, E5 transfer, E6 completion or reboot was sent in this Mac check. `budsctl firmware-check` never installs firmware. Nineteen tests passed, including multiple MTUs, acknowledgment ordering and failed-write queue reset. Full Mac OTA transfer and physical cancellation/recovery remain unverified; a newer official release is needed for a normal update test.


### Pending RFCOMM opens — 9 October 2026

On the installed 0.4.0 Mac app, a channel-28 open did not complete within ten seconds. The app discarded the pending channel and retried. macOS logged `Already connected to device`, then `OI_RFCOMM_Connect failed (status=911)` after the app restarted; 911 is `OI_RFCOMM_DLCI_EXISTS` in the [Open Interface status definitions](https://android.googlesource.com/platform/packages/modules/Bluetooth/+/a5a1f4f32268a9bdff15978dcf6126825a8e0c44/system/embdrv/sbc/decoder/include/oi_status.h). Disconnecting the iPhone did not resolve the Mac failure. A normal `IOBluetoothDevice.closeConnection()` disconnected audio profiles but left the baseband/control channel stuck. The original reason the first open hung is not established, so this does not prove a firmware regression.

The Mac controller now retains an opening channel after its timeout, fails outstanding operations, and offers earbud-restart instructions instead of starting duplicate opens. It accepts a late successful completion and resets on an actual Bluetooth disconnect. Duplicate SDP/open-completion callbacks cannot replace or close the current channel. Tests exercise these paths using fake IOBluetooth devices/channels without hardware or setting writes.

Live read-only verification after the case restart succeeded with only the right earbud available: firmware 1.2.3.7, right battery 100%, left/case battery unavailable, noise mode Off. The installed patched app repeatedly reopened, read and released channel 28 without timeouts, and recovered automatically from the physical case restart at 2026-10-09T15:24:59Z. The device-info peer-version bytes were `10 01` with the other bud absent; this does not verify the missing earbud's firmware. The original stall may involve single-earbud use or firmware behavior, but that trigger remains unproven.

## Earbud settings (2717/50E3, firmware 1.2.3.7)

Independent Mac RFCOMM and iPhone authenticated BLE reads on 8 October 2026 agree:

- F3 / 0002 returns triples `[gesture, left action, right action]`: gesture 4 single tap, 1 double tap, 2 triple tap, 3 hold, 5 swipe. The pair returns action 8 (None) for all taps/holds and 11 (volume) for swipes. p76c's catalog permits tap actions 8/1/2/3/4/5, hold 8/0/6, swipe 8/11.
- F2 edits one gesture using an FF sentinel for the untouched side. Readback checks every record, including unknown gesture IDs and the untouched side; record order may change.
- 000A is left/right noise-cycle bit masks: Off=1, ANC=2, Transparency=4. At least two bits must be selected. The pair reports 6/6.
- 0003 automatic answer=0, 0004 multipoint=1, 0007 EQ preset=0, 001D spatial bitfield=0, 0025 adaptive ANC=0, 0029 adaptive sound=0, 002F low latency=0, 0036 scene=`00 01`, 0006 fit result=`00 00`.
- Spatial 001D uses bit0 enabled, bits1–2 audio preference (0 quality, 1 latency), bit3 head tracking. Preserve the preference when changing modes. 0068 selects Xiaomi/Dolby engine; the p76c catalog lists choices 0/1. Its readback must be present and valid before edits are enabled.
- 0037 EQ reply is `[1, mode, upper bound, lower bound, EQ ID, name length, name..., band count, (frequency BE16, signed-magnitude gain)*]`. This pair reports 10 bands: 62/125/250/500/1000/2000/4000/8000/12000/16000 Hz, gain bound 6, all gains zero. Negative gain encodes as `128 + magnitude`. The curve reply's mode is not the active preset: 0007 must confirm Custom (10) before band editing is enabled. Custom writes use header `[1,10,1,1,1,0,count]` and preserve all other frequencies/gains; readback compares mode and every band, not response-only header bytes.
- In-ear detection reads 09 with mask `00 00 04 00`, response attribute 0A: 0 enabled, 1 disabled. Its 08 write is `[02,06,inverted boolean]`, followed by independent 09 readback. It is not an F2 config toggle.
- Explicit fit test uses F2 / 0005 `[1]`, then polls 0006 after the test delay; 1 good, 2 poor, 9 not worn. Find uses F2 / 0009 `[enabled,ear ID]`, ear ID 1 left/2 right/3 both. Before starting a find sound, F3 / 000C must affirm both in-ear bits (3/2) clear. Stop sends `[0,3]` without requiring the out-of-ear condition.

The model does not answer F3 / 0008 (generic firmware name); including it in a combined query also times out. The shipped settings screen omits this query. Reads are individual and serialized. OS Bluetooth nicknames are distinct from supported earbud configuration.

No supported call hang-up override was found in the model catalog, public protocol or SDK setting types. Media gesture None must not be presented as disabling call handling: this pair already has all taps/holds set to None and the user still reports accidental hang-ups. Do not write guessed config IDs or reinterpret the SDK's unrelated lab listening-duration setting as call control. No proprietary implementation source is bundled.
