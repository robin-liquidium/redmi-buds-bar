# Redmi Buds for iPhone

Native SwiftUI app for REDMI Buds 8 Pro, with direct Bluetooth LE control. No Xiaomi account or Mac bridge is required. The app authenticates the private MMA Bluetooth session before reading controls. The shared packet parser is the same source used by the Mac app.

## Sideloading

Future releases include an unsigned device IPA with the Control Center extension and checksums. You must sign it with your own identity and shared App Group; see [signing instructions](SIDELOADING.md). Existing v0.4.0 predates this release flow.

## Features

- Noise cancelling, transparency and off, confirmed by an independent readback after each write.
- Twenty manual ANC strength positions. Changing strength disables smart ANC when necessary and confirms that change.
- Regular, Voice and Ambient transparency presets.
- Left/right battery levels, case battery when reported, and both earbud firmware versions.
- Official Xiaomi firmware checks and downloads without an account, with an explicit on-device update action.
- One cycling Control Center button with a mode-specific icon, plus optional direct mode buttons and Shortcuts actions.
- Shared verified peripheral identity, background Bluetooth support and state restoration.
- Control-channel release after idle and reconnection for the next action; audio stays connected.
- Silent foreground refresh every 30 seconds after the previous read finishes, including battery and charging state. The native circular refresh button in the device card shows a spinner only for manual refresh. Successful background reads do not animate connection status or disable the button.

## Build and install

Requires iOS 26+, Xcode with the matching device SDK, XcodeGen and an Apple development signing team. Change `DEVELOPMENT_TEAM` and bundle identifiers in `project.yml` for another developer account.

```sh
xcodegen generate --spec iOS/project.yml
open iOS/RedmiBuds.xcodeproj
```

Select the RedmiBuds scheme and your paired iPhone, then Run. Allow Bluetooth when prompted. Pair the earbuds in iPhone Bluetooth settings; open their case if the app cannot discover them.

To install from the command line, use your device's identifier as the Xcode destination and pass the resulting `RedmiBuds.app` to `xcrun devicectl device install app`.

## Control Center

Open Control Center, touch and hold, choose **Add a Control**, and search **Redmi Buds**. Add **Cycle noise mode** and remove the individual mode controls if desired. Each tap reads the current mode and advances ANC → transparency → off → ANC without opening the app. The label and icon show the last confirmed mode through an App Group and WidgetKit reloads. Updates follow iOS's control refresh scheduling; the displayed state is not used to choose the next mode. Existing direct mode controls remain available.

The public ControlWidget API exposes buttons and toggles, not custom expanded long-press panels. iOS requires the user to add and remove controls. Command success requires independent device readback.

## Verification and limits

On 8 October 2026, firmware 1.2.3.6/product 0x50E3 on Robin's Chinese-market pair answered direct iPhone mode writes with matching readbacks. The three-mode check passed both with the Mac disconnected and with its Bluetooth connection restored. Robin confirmed that the app's mode buttons and the direct ANC/transparency Control Center buttons work. The cycling action and its shared confirmed icon state passed a physical-device check; Robin then confirmed that cycling and mode-specific icon changes work from Control Center. Repeated sleep/wake, locked-phone execution and long-term multipoint handoff require daily-use testing; this does not provide Apple's proprietary AirPods automatic switching.

In Debug builds only, launching with `--verify-noise` runs the actual direct-mode and cycling App Intents, checks readbacks/shared icon state, restores the initial active mode and strength, and writes `Documents/device-verification.txt`. Release builds exclude this check.

The first C4 controller used the public LE Audio endpoint, whose discovery window required pairing mode. The current implementation uses Xiaomi’s private manufacturer-advertised endpoint and the authenticated C0/00 session instead. Its identity is shared with the controls extension after a successful authentication and model/control read, and retained through temporary connection timeouts. The controller releases its idle GATT connection without clearing confirmed readings; the UI shows Ready and reconnects for a control action. The Mac controller similarly releases idle RFCOMM to avoid keeping the other host out. Foreground polling reacquires the control connection for a read, then releases it again; it stops when the app is inactive and skips mode changes or firmware operations. A timed-out initial authentication challenge gets one bounded retry with a fresh nonce to allow the other host to finish. A stale Bluetooth bond is reported separately. Build 6 passed authenticated direct-mode/cycle/icon checks and a Mac → iPhone → Mac control handoff with Mac audio connected. This is a verified short handoff, not a guarantee of sustained multipoint or sleep/wake reliability. Battery dashes mean unavailable readings. Earbud settings now includes gestures, noise-cycle masks, in-ear detection, dual connection, automatic answering, adaptive sound/ANC, dimensional audio and EQ. Read-only settings on firmware 1.2.3.7 were verified on both transports; the new writes and sound/test tools need manual device verification. See the [settings feature list and limitations](../README.md#earbud-settings), including separate firmware call gestures and system Bluetooth renaming. A complete 1.2.3.6 → 1.2.3.7 firmware update was verified on the physical pair, including both earbud versions after restart.

Noise strengths are remembered when observed during the current app session; initial defaults are ANC 19 (UI level 20) and Regular transparency. Only the verified product ID is accepted for commands. Other firmware or regional variants may need a different protocol.

Connection diagnostics are recorded locally by the app and controls in the shared App Group. They include Bluetooth state, discovered controls, exact errors, command opcodes/sequences, timeouts and confirmed mode/battery/firmware readings. Authentication payloads, pairing keys and audio are not logged. The app and controls extension each keep a current log and one previous log, approximately 512 KiB per file. The logs survive app restarts and can be retrieved from the connected iPhone over USB without asking the user to repeat error messages. There are no accounts, analytics or audio capture. Network requests are limited to Xiaomi firmware discovery and downloads initiated by the user. The app does not change the audio route or reset the earbuds. Firmware commands run only after the user taps Update earbuds.

## Firmware updates

Open **Firmware**, check for updates, download the package, then tap **Update earbuds**. Both earbuds must be charged and in the open case. Keep the app open, and disconnect the earbuds from the Mac and other devices for the update. The app prevents sleep during the transfer and blocks noise commands until it finishes.

The official Xiaomi guest firmware service returns this exact model's package without a personal account. The download must use Xiaomi's HTTPS CDN, match the server checksum, and pass model, version, length and image CRC checks. The OTA image's declared length excludes Xiaomi's appended signing envelope. No proprietary app source or archive firmware is bundled.

The implementation follows Xiaomi's [published OTA protocol](https://developers.xiaoai.mi.com/api/doc/render_markdown/VoiceserviceAccess/Bluetooth/BluetoothProtocol/OTAUpgrade): E1/E2 compatibility queries, E3 entry, device-requested E5 blocks with optional CRC and delay, E4 cancellation, E6 verification, then reboot and independent version readback of both earbuds. Only the confirmed dual-bank flow is supported. Update success requires both versions to match the downloaded release.

The captured official app attempt failed with code 0x10: the earbuds lost their link to each other. This is distinct from the iPhone audio connection. Code 0x12 means both earbuds are not in the open case. The app displays these reasons directly. Build 7 on the physical pair verified official discovery/download and the read-only readiness queries, correctly rejecting low earbud battery. Release 7 normal connection/charging diagnostics were verified. Release 9 then completed an official 1.2.3.6 → 1.2.3.7 update on 8 October 2026. The system trace contained 756 firmware blocks; every block and CRC matched the official image. E6 confirmed verification and the reboot command was acknowledged. Both earbuds returned 1.2.3.7 after about 80 seconds. The original completion window expired too early; build 10 allows two minutes for restart/readback and reconciles a later version confirmation. This establishes the tested model/version transition, not every future update or interrupted-update recovery.

Debug builds also accept `--verify-firmware-readiness`: official package discovery/download validation and E1/E2 queries only. It never enters OTA mode, transfers data or reboots the earbuds.

## Retrieve diagnostics

With the trusted iPhone connected and unlocked, copy the shared logs using its CoreDevice identifier:

```sh
xcrun devicectl device copy from --device DEVICE_ID \
  --domain-type appGroupDataContainer \
  --domain-identifier group.build.robin.RedmiBuds \
  --source Library/Diagnostics --destination work/ios-research/app-diagnostics --timeout 15
```

`app.jsonl` and `controls.jsonl` contain timestamped JSON events with a process/session identifier and build number. The files are local diagnostics, not a remote monitoring service. The Apple Bluetooth logging profile and USB PacketLogger capture provide separate system-level evidence; the app cannot inspect all activity on the iPhone.

## License

The iPhone app incorporates a Swift adaptation of [BudsLink’s Xiaomi authentication implementation](https://github.com/maniacx/BudsLink/blob/main/src/lib/devices/redmiBuds/redmiBudsAuthenticator.js) and is distributed under GPL-3.0-or-later. See COPYING and the bundled Shared/ThirdPartyNotices.txt. The authentication response was independently matched to a complete captured Xiaomi-app challenge/response pair.
