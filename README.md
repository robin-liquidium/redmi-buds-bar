# Redmi Buds Bar

A small native macOS menu bar app for REDMI Buds 8 Pro. Verified with a Chinese-market pair, product ID `0x50E3`, firmware `1.2.3.6`, on 9 September 2026.

## Download

[Website](https://buds.robin.build) · [Latest release](https://github.com/robin-liquidium/redmi-buds-bar/releases/latest)

```sh
brew install --cask robin-liquidium/tap/redmi-buds-bar
```

Requires macOS 14 or later. Public releases contain a universal app for Apple silicon and Intel. Install it in Applications, pair your earbuds, and open the app.

## Working features

- Noise cancelling, transparency, and off.
- ANC strength slider below the mode controls, with 20 manual positions.
- Three-position transparency slider: Regular, Voice, Ambient.
- Moving ANC strength turns off smart ANC when necessary, with acknowledgment and readback.
- Strength changes are sent when a drag finishes; keyboard adjustments also work.
- Left/right battery levels; case battery when the earbuds report it.
- Firmware version.
- Device state refresh on opening the popover and every 30 seconds.
- Acknowledges device notifications and reads back the current mode.
- Reconnects the control channel when the already-paired buds reconnect to the Mac.
- Checks Bluetooth connection status every 2 seconds, with 0.2 seconds of timer tolerance to help macOS save power. Battery and control polling stays at 30 seconds.
- Confirms a mode change only after the earbuds acknowledge it and a separate query matches it.

The earbuds icon appears in the menu bar only while your REDMI Buds 8 Pro are connected. Enable **Always show menu bar icon** in the settings menu to keep it visible when disconnected. The preference is saved across launches and is off by default. Reopen the app from Applications while the icon is hidden to access its controls and settings.

The app runs without a Dock icon. Use the settings menu to enable **Launch at login**, manage automatic updates, or check for a new version.

## Build and run

Requires macOS 14 or newer and an installed Swift 6 toolchain / Xcode. The included binary was built and tested on this Mac with its installed Xcode beta; other OS versions are not yet tested.

```sh
./script/build_and_run.sh
```

The script builds a release executable, packages `outputs/RedmiBudsBar.app`, signs it locally, and opens it. Other options: `--show`, `--verify`, `--build-only`, `--logs`.

```sh
swift test
```

Seven tests cover real captured packets, fragmentation, combined broadcasts, invalid lengths/trailers, battery sentinels, and noise command encoding.

The `budsctl` executable shares the app's transport and protocol implementation. Quit the menu bar app before using it so two clients do not compete for the control channel.

```sh
swift run budsctl status
swift run budsctl transparency
swift run budsctl off
swift run budsctl anc
swift run budsctl anc 9              # wire strength 9 (UI level 10)
swift run budsctl transparency 2    # Ambient
```

The Codex Run action uses the same build script.

## Limits

- EQ, gestures, spatial audio, and firmware updates are not exposed. Smart ANC can be turned off automatically by the strength slider, but there is no separate smart ANC switch.
- Switching back to a mode preserves its last strength read during this app session. Before observing ANC/transparency in the current session, the defaults are the verified ANC value 19 and standard transparency 0.
- A dash for the case means its battery is unavailable, not empty.
- Reconnect handling is implemented; repeated sleep/wake and multipoint handoff behavior still need daily-use testing.
- A future firmware or another regional variant could require a different handshake. This version reports connection/read errors rather than attempting undocumented authentication.
- Public releases are Developer ID signed and notarized. Builds made locally with the default script use an ad-hoc signature.

## Privacy and diagnostics

No account, analytics, or phone is needed. Sparkle checks for signed updates at `buds.robin.build` and downloads them from GitHub; you can disable automatic updates in settings. Bluetooth data stays on your Mac. It talks to paired devices whose name matches REDMI Buds 8 Pro, using Apple's IOBluetooth framework.

A local diagnostic log is written to `~/Library/Logs/RedmiBudsBar.log`, reset on launch and capped at approximately 256 KB. It contains protocol packets and status, not audio. The app never changes the Bluetooth audio route or sends firmware-update/factory-reset commands.

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
