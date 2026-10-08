# Install Redmi Buds for iPhone

The `RedmiBuds-VERSION-unsigned.ipa` release asset is a physical-device build for iOS 26 or later. It includes the Control Center extension. It is **not installable until re-signed** with certificates and provisioning profiles valid for your iPhone. It is not a TestFlight or App Store download.

Verify the IPA against the release's `SHA256SUMS` before signing it. The public package contains no personal provisioning profiles, device identifiers or signing credentials.

## Signing requirements

Sign both `Payload/RedmiBuds.app` and its `PlugIns/RedmiBudsControls.appex` extension with your own team. Each needs a matching bundle identifier and provisioning profile. Your signing method must retain the WidgetKit extension, Bluetooth background mode and a shared App Group authorized for **both** targets.

The default App Group is `group.build.robin.RedmiBuds`. When your team uses a different group, change `BudsAppGroupIdentifier` in **both** Info.plist files and include that same group in both signatures' `com.apple.security.application-groups` entitlement. Changing entitlements alone is insufficient: the app reads that Info.plist key to find its shared preferences and diagnostics. Sign the extension first, then the app. Do not remove the extension to make signing succeed: that removes Control Center support.

Apple-signed development/ad hoc packages run only on devices included in their provisioning profiles. Enable Developer Mode when required by your installation method. A third-party re-signing tool is usable only if it supports these identifiers, entitlements and the embedded extension; free-account/full-feature compatibility is not assumed.

## Build with Xcode instead

Clone the source and open `iOS/RedmiBuds.xcodeproj`. Set your own development team and bundle identifiers on both targets, register an App Group in your team, and set the shared `BUDS_APP_GROUP` build setting to that group. Xcode expands that setting into both targets' entitlements and Info.plist files. Choose your iPhone and Run. See [the iPhone README](https://github.com/robin-liquidium/redmi-buds-bar/tree/main/iOS).

After installation, allow Bluetooth, open Redmi Buds and confirm that a mode change is read back. Add **Cycle noise mode** from Control Center and confirm it works and its icon changes. This verifies the shared-group/extension signing as well as the main app. Repeat this check after changing signing tools or identifiers.

Apple references: [registered-device distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices), [App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups).
