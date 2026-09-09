# Releasing Redmi Buds Bar

Use `$redmi-buds-release` in Codex. The canonical skill lives in `.agents/skills/redmi-buds-release/`.

## Source of truth

- `release.json`: next/current tagged version, monotonically increasing Sparkle build number, date, user-facing changes.
- `website/public/releases.json`: published changelog history, updated only after a public release exists.
- `website/public/appcast.xml`: exact signed feed produced by Sparkle. Never hand-edit it.
- GitHub release `release-state.json`: stage, exact source commit, artifact hashes, Apple submission IDs. Contains no secrets.

The app is GPL-3.0. Sparkle retains its upstream license inside the bundled framework. Packaging conventions are adapted from Robin's Dayline project (also GPL-3.0).

## One-time credentials (already configured)

GitHub Actions uses six repository secrets: `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `APP_STORE_CONNECT_KEY_P8_BASE64`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, and `SPARKLE_PRIVATE_KEY`.

The Apple Developer ID identity is `Developer ID Application: Robin Obermaier (5S5288W3R7)`. The Sparkle private key has its own `redmi-buds-bar` account in Robin's macOS login Keychain. Preserve it for all future releases; never generate a replacement casually. The public key is committed in `script/package_app.sh`.

The final distribution step runs on a Mac with `gh`, `bun`, Homebrew, Swift, and Wrangler authentication. Cloudflare account: `81b27ab7c6fe3a3b3a0e6d31f7d2a381`; Worker: `redmi-buds-bar-website`; custom domain: `buds.robin.build`.

## Release sequence

1. Update `release.json`; run tests, universal packaging, website checks/build, and code review.
2. Commit/push main, wait for CI, then tag the exact commit `vVERSION` and push the tag.
3. The Release workflow creates a draft and submits the signed universal app ZIP. Its state and exact artifact are uploaded to the draft.
4. While Apple says `In Progress`, the workflow returns without blocking a runner. The scheduled workflow retries every 20 minutes. `gh workflow run release.yml -f tag=vVERSION` resumes sooner.
5. After app acceptance, it restores the same archive, staples and validates the app, makes the final Sparkle ZIP, creates the styled DMG, and submits that DMG separately.
6. After DMG acceptance, it staples and validates it, signs the Sparkle archive/feed/release notes, uploads versioned and stable-name DMGs, checksums, and notarization evidence, then publishes the release.
7. Run `python3 script/finalize_release.py vVERSION` on Robin's Mac. It verifies signatures/checksums, updates the feed and changelog, deploys the website, checks live bytes, updates the cask, and fetches it with Homebrew. This is part of the release skill, not an unattended GitHub Actions step.

GitHub's scheduled workflows can be delayed or disabled after inactivity; manual dispatch remains available. Only one release may be in flight. Do not start the next version until distribution of the current one is complete.

## Interrupted or rejected notarization

Read the draft's `release-state.json`. `app_pending` and `dmg_pending` are normal; keep the saved archive unchanged. The script downloads it and verifies SHA-256 before continuing.

`app_submitting` or `dmg_submitting` means the submission result was ambiguous. Inspect `xcrun notarytool history` using the configured Apple credentials, match the submission name/time to the saved archive, and obtain its submission ID. Save that ID as `app_submission_id` or `dmg_submission_id`, change the phase to the corresponding `_pending`, and upload the corrected state to the same draft. Do not submit again unless Apple history establishes that no submission exists. Record the reconciliation in the release notes/work log.

For `_rejected`, inspect `xcrun notarytool log ID` and fix the actual issue. Never staple, publish, or bypass Gatekeeper for a rejected artifact. A code change requires a new version/build and tag. Keep the rejected draft as evidence or explicitly retire it before starting another release.

## Manual packaging

`./script/package_app.sh --universal` makes an ad-hoc development bundle in `outputs/`. Set `SIGNING_IDENTITY` to the Developer ID identity for distribution signing. The script embeds and signs Sparkle inside out.

`./script/package_dmg.sh` packages the existing bundle using `Resources/DMGBackground.svg`, rendered into a multi-resolution TIFF at 1× and 2× for crisp Retina text. It does not notarize by itself. The release workflow notarizes and staples both artifacts.

## Release checks

Verify `codesign --verify --deep --strict`, `lipo -archs` (both `arm64` and `x86_64`), `xcrun stapler validate`, and Gatekeeper. Verify the signed feed and ZIP with Sparkle's `sign_update --account redmi-buds-bar --verify` tool. A feed signature is not a completed end-user upgrade: test an actual older installed version through Check for updates when changing the updater integration.

The app uses `SMAppService.mainApp` for its optional launch-at-login setting. Register only the app installed at a stable path. If macOS returns `requiresApproval`, the settings menu exposes a button to Login Items; do not claim the setting is enabled until the service reports `.enabled`.
