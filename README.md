# Redmi Buds Bar

A small native macOS menu bar app for REDMI Buds 8 Pro. Verified with a Chinese-market pair, product ID `0x50E3`, on firmware `1.2.3.6` and `1.2.3.7`.

## Download

[Website](https://buds.robin.build) · [Latest release](https://github.com/robin-liquidium/redmi-buds-bar/releases/latest)

```sh
brew install --cask robin-liquidium/tap/redmi-buds-bar
```

Requires macOS 14 or later. Public releases contain a universal app for Apple silicon and Intel. Install it in Applications, pair your earbuds, and open the app.

## iPhone app

The native [iPhone app](iOS/README.md) uses direct Bluetooth LE for noise modes, ANC strength, transparency presets and battery levels. It includes one cycling Control Center button with a mode-specific icon, optional individual controls and Shortcuts actions. Official Xiaomi firmware discovery, download and installation work without an account; a complete 1.2.3.6 → 1.2.3.7 update was verified on the Chinese model. Requires iOS 26 or later. Releases from 0.5.0 include a separate unsigned IPA with the controls extension; [sideloading requires your own signing and shared App Group](iOS/SIDELOADING.md). You can also build from Xcode. The Mac DMG is a separate download.

## Working features

- Now Playing card with artwork, track, artist, and source app, plus previous, play/pause, next, and a seek bar.
- Click the source app name to open it. Press Space while the popover is open to play or pause.
- Playback updates arrive as events; the media helper stops when the app's controls close.
- Noise cancelling, transparency, and off.
- ANC strength slider below the mode controls, with 20 manual positions.
- Three-position transparency slider: Regular, Voice, Ambient.
- Moving ANC strength turns off smart ANC when necessary, with acknowledgment and readback.
- Strength changes are sent when a drag finishes; keyboard adjustments also work.
- Left/right battery levels; case battery when the earbuds report it.
- Both earbud firmware versions.
- Official Xiaomi firmware checks, validated downloads and an explicit firmware update action in **Settings → Earbud firmware…**. No Xiaomi account is needed.
- Device state refresh on opening the popover and every 30 seconds.
- Acknowledges device notifications and reads back the current mode.
- Reconnects the control channel when the already-paired buds reconnect to the Mac.
- Keeps a slow control-channel opening pending instead of repeatedly opening duplicate channels. If it stalls, the menu explains how to restart the buds; a late successful connection or Bluetooth reconnect restores controls automatically.
- Checks Bluetooth connection status every 2 seconds, with 0.2 seconds of timer tolerance to help macOS save power. Battery and control polling stays at 30 seconds.
- Confirms a mode change only after the earbuds acknowledge it and a separate query matches it.

The earbuds icon appears in the menu bar only while your REDMI Buds 8 Pro are connected. Enable **Always show menu bar icon** in the settings menu to keep it visible when disconnected. The preference is saved across launches and is off by default. Reopen the app from Applications while the icon is hidden to access its controls and settings.

The menu uses SwiftUI's native MenuBarExtra window style, letting macOS draw its outer shape and material. Packaging records the actual build SDK while retaining the macOS 14 deployment target, so current macOS versions use their current appearance. The app runs without a Dock icon. Use the settings menu to enable **Launch at login**, manage automatic updates, or check for a new version.

## Earbud settings

Choose **Settings → Earbud settings…** on Mac or **Earbud settings** on iPhone. Both use the same model-specific settings codec and offer:

- Left/right single, double and triple taps, press-and-hold and swipe assignments, including None.
- Hold-to-cycle noise modes with at least two modes selected per earbud.
- In-ear detection, dual connection and automatic call answering.
- Adaptive ANC, adaptive sound and low latency.
- Dimensional audio, head tracking, audio preference and scene presets.
- Default, Bass, Voice, Treble and Custom EQ, with ten frequency bands and the gain limit reported by the buds. Select Custom before editing its bands.
- An explicit ear tip fit test and find sound. Find refuses to start while either bud reports being worn; Use Stop sound to stop it sooner and keep the app open for the 30-second stop request.

Opening settings only reads. Every persistent change reads fresh state, writes only the selected field, and independently verifies the result. Unsupported settings are omitted. The menu's existing design is unchanged.

Read-only settings were verified on both Mac and iPhone with firmware 1.2.3.7. New setting writes, fit tests and find sounds still require user testing. **Normal tap/hold assignments do not disable the firmware's separate call answer/end/reject behavior.** No configurable hang-up command has been identified for this model. Rename the earbuds in system Bluetooth settings; the generic firmware-name query is unsupported on this pair. These limitations mean this is not a claim of complete Xiaomi-app parity.

## Earbud firmware

Open the menu bar app's gear menu and choose **Earbud firmware…**. Check for updates, download the official firmware, then choose **Update earbuds**. Charge both earbuds and the case, put both earbuds in the case with its lid open, and disconnect the buds from your iPhone and other devices during the update. The Mac app keeps the transfer running if its firmware window closes and prevents idle system sleep until it finishes.

The updater supports the Chinese REDMI Buds 8 Pro model (2717/50E3) and its dual-bank update flow. It validates Xiaomi's download, reads the buds' readiness response, sends the blocks they request and confirms both versions after reboot. Firmware is installed only after you choose **Update earbuds**.

Mac checks, official downloads and read-only readiness queries were verified on 8 October 2026. A complete update using the same image format and protocol was verified on iPhone. A complete Mac transfer and interrupted-transfer recovery await a newer firmware release; this implementation has not been physically tested flashing the buds from the Mac. The installed pair is already on 1.2.3.7.

## Build and run

Requires macOS 14 or newer and an installed Swift 6 toolchain / Xcode. The included binary was built and tested on this Mac with its installed Xcode beta; other OS versions are not yet tested.

```sh
./script/build_and_run.sh
```

The script builds a release executable, packages `outputs/RedmiBudsBar.app`, signs it locally, and opens it. Other options: `--show`, `--verify`, `--build-only`, `--logs`.

```sh
swift test
```

Thirty-one Swift tests cover captured packets, fragmentation, combined broadcasts, invalid lengths/trailers, battery sentinels, noise commands, earbud settings, playback updates and timing, firmware integrity/version validation, serialized writes across Bluetooth MTUs, and pending connection recovery. Eleven Python tests cover release state and unsigned iPhone packaging.

The `budsctl` executable shares the app's transport and protocol implementation. Quit the menu bar app before using it so two clients do not compete for the control channel.

```sh
swift run budsctl firmware-check   # discovery/download/readiness only; never installs
swift run budsctl status
swift run budsctl transparency
swift run budsctl off
swift run budsctl anc
swift run budsctl anc 9              # wire strength 9 (UI level 10)
swift run budsctl transparency 2    # Ambient
```

The Codex Run action uses the same build script.

## Limits

- Playback integration uses the private macOS MediaRemote framework through the bundled [MediaRemote Adapter](https://github.com/ungive/mediaremote-adapter). Future macOS updates may break it. Only media that apps publish to the system's Now Playing service is shown; controls depend on the source app's support.
- Earbud settings expose only fields supported by the verified model. Call answer/end/reject behavior and renaming are not configurable here.
- Switching back to a mode preserves its last strength read during this app session. Before observing ANC/transparency in the current session, the defaults are the verified ANC value 19 and standard transparency 0.
- A dash for the case means its battery is unavailable, not empty.
- Reconnect handling is implemented; repeated sleep/wake and multipoint handoff behavior still need daily-use testing.
- A future firmware or another regional variant could require a different handshake. This version reports connection/read errors rather than attempting undocumented authentication.
- Public releases are Developer ID signed and notarized. Builds made locally with the default script use an ad-hoc signature.

## Privacy and diagnostics

No account, analytics, or phone is needed. Sparkle checks for signed updates at `buds.robin.build` and downloads them from GitHub; you can disable automatic updates in settings. Firmware checks and downloads contact Xiaomi's official service and CDN. Bluetooth data stays on your Mac. It talks to paired devices whose name matches REDMI Buds 8 Pro, using Apple's IOBluetooth framework.

Now Playing metadata and artwork stay local and are not logged. The bundled BSD-licensed media adapter runs through `/usr/bin/perl` only while the controls are visible. No media service account or browser extension is needed.

Controls are created when opened and released when closed. Closing the player also clears its metadata and artwork cache. Artwork is decoded to a 128-pixel thumbnail for the 64-point Retina display, and playback changes reuse the cached artwork without re-encoding it. The progress clock runs only while a visible track is playing; the background Bluetooth check remains every 2 seconds.

A local diagnostic log is written to `~/Library/Logs/RedmiBudsBar.log`, reset on launch and capped at approximately 256 KB. It contains protocol packets and status, not audio. Firmware operations log command metadata rather than firmware payloads. The app sends firmware-installation commands only after the explicit **Update earbuds** action and never sends factory-reset commands. Normal controls preserve the Bluetooth audio connection; an explicit firmware check or update can reconnect the paired buds when needed.

## Research and attribution

See `PROTOCOL.md` for verified commands and evidence. Existing Xiaomi protocol research and BudsLink pointed to the service and configuration fields. This Swift implementation uses those protocol facts and independently captured responses; no third-party authentication code or binary is bundled.

- [BudsLink Xiaomi transport](https://github.com/maniacx/BudsLink/blob/main/src/lib/devices/redmiBuds/redmiBudsSocket.js)
- [BudsLink Buds 8 Pro profile](https://github.com/maniacx/BudsLink/blob/main/src/lib/devices/redmiBuds/deviceConfigs/RedmiBuds8Pro.js)
- [TWS-Pods-PC Xiaomi protocol research](https://github.com/Zhaoyi-ya/TWS-Pods-PC/blob/main/xiaomi/PROTOCOL.md)
- [Apple IOBluetooth RFCOMM API](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/openrfcommchannelasync(_:withchannelid:delegate:))

## Website and releases

The landing page is static Astro with locally hosted fonts and plain CSS, deployed with Cloudflare Workers Static Assets. Run `cd website && bun install && bun run dev` to develop it. Dependencies are pinned with a committed lockfile.

See [RELEASING.md](RELEASING.md) and the [release skill](.agents/skills/redmi-buds-release/SKILL.md) for the complete signing, notarization, Sparkle, website, and Homebrew workflow.

Licensed under [GPL-3.0](LICENSE).
