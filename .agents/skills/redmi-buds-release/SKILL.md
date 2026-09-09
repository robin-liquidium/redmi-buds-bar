---
name: redmi-buds-release
description: Release Redmi Buds Bar end to end, including changelog, universal signed app, resumable Apple notarization, DMG, GitHub release, Sparkle feed, Astro Cloudflare website, and Robin's Homebrew tap. Use when Robin asks to ship or update Redmi Buds Bar.
---

# Redmi Buds Bar release

A request to use this skill authorizes the release commits, tag, GitHub publication, Cloudflare deployment, and Homebrew cask update. Finish the concrete release without asking again for those steps.

## Find the repository

Use the current checkout if its origin is `robin-liquidium/redmi-buds-bar`. Otherwise find the existing checkout before cloning. Read `RELEASING.md` and the scripts in that checkout. Do not change Dayline or its release keys.

## Prepare

1. Inspect git status and existing GitHub drafts/runs. Resume an existing release first. Never rebuild or resubmit an artifact Apple is already reviewing.
2. Work from clean `main`, fetch and fast-forward. Preserve unrelated user changes. Verify `gh api user` is `robin-liquidium` and Cloudflare authentication is available with `cd website && bun x wrangler whoami`.
3. Read changes since the latest public tag. Update `release.json` with a suitable semantic version, a strictly increasing integer build, today's date, and concise user-facing changes. Do not invent improvements. A tag must match the version exactly. Inspect existing public and draft builds before choosing the next build.
4. Run `swift test`, `./script/package_app.sh --universal`, then `cd website && bun install --frozen-lockfile && bun run check && bun run build`. Use the autoreview skill if available for nontrivial code changes. Verify the macOS minimum and both architectures with `vtool` and `lipo`. Inspect UI when it changed; do not force the user's audio mode for packaging tests.
5. Commit the release, push main, and wait for CI to pass on that commit. Tag `vVERSION` at that exact commit and push the tag. Do not move a published tag.

## Notarize and publish

The `Release` workflow signs the app, saves draft artifacts and notarization IDs, submits to Apple, staples the app, creates the custom DMG, submits and staples the DMG, signs Sparkle's feed and ZIP, and publishes only when all checks pass.

Watch the relevant run. A successful job with a draft still present means publication is pending. Inspect the saved phase and logs: Apple may be processing it, or GitHub may still be indexing a newly created draft. The scheduled workflow resumes drafts every 20 minutes. You may dispatch `gh workflow run release.yml -f tag=vVERSION` to check sooner. Use bounded waits, communicate meaningful status, and continue independent work while waiting. Do not dispatch overlapping jobs repeatedly.

For ambiguous submissions or rejection, follow `RELEASING.md`. Report Apple's actual status and submission ID. Never claim notarization is complete while pending.

## Finish distribution

Once the release is public, run `python3 script/finalize_release.py vVERSION` from clean main on Robin's Mac. It verifies the release checksums, Sparkle signatures, and notarized DMG; commits the feed and website changelog; deploys Astro to Cloudflare; verifies the live feed byte-for-byte; updates `robin-liquidium/homebrew-tap`; and fetches the cask through Homebrew.

This step uses local GitHub/Cloudflare authentication and the `redmi-buds-bar` Sparkle key in macOS Keychain. No Cloudflare token is stored in the public repository. The script is safe to rerun after an interrupted deploy; inspect and commit any generated feed/changelog changes first if a build failed before its commit.

Verify the production landing page, download redirect, changelog, exact signed feed, and tap workflow status. All download URLs must use this release's files; no draft link may appear on the site. Release notes and app metadata come from `release.json`, with published history in `website/public/releases.json`.

Do not replace the installed app during routine releases. Leave the user able to exercise Sparkle. For an explicit first install, copy the verified app into `/Applications/RedmiBudsBar.app`, then open it. If Robin asks to enable login launch, open the installed app with `--enable-login` and verify ServiceManagement's state.

Report the version, website, release URL, Homebrew command, and any concrete unverified behavior. Distinguish build/signature/feed verification from a completed in-app Sparkle upgrade.
