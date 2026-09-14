# Changelog

## 0.1.8 — 2026-09-14

- Track open marketplace listing and verification issues (read-only GitHub search). Session Restore shows `in review #6398` while that issue is open. Press `i` to open it. No GitHub token; a search failure leaves catalog stats alone.

## 0.1.7 — 2026-09-12

- Unlisted plugin repo links come from `.git/config` origin (so Tempest Weather opens `dreed47/tempest-weather`, not a guessed `omarchy-tempest-weather`). The guess remains only when there is no origin.

## 0.1.6 — 2026-09-12

- Count git worktree installs: a plugin directory that is one absolute symlink under `$HOME` is included after walking the target from HOME with the same ownership and no-group-write checks. Relative links and targets outside HOME stay skipped.

## 0.1.5 — 2026-09-12

- Reject group- or world-writable directories on the HOME → state/plugins walk. Plugin-owned state leaf is forced to `0700` and cache files to `0600` via `fchmod` on the opened fd (survives umask). Shared ancestors are not chmod'd. Group-writable plugin checkouts are skipped, not followed.

## 0.1.4 — 2026-09-11

- Address marketplace supply-chain review: one `/usr/bin/python3 -I` helper with a closed environment, no `bash -c`, host-allowlisted HTTPS, hard process deadline, bounded stdout, and cache I/O descriptor-relative under an ownership-checked no-follow directory.

## 0.1.3 — 2026-09-10

- Include this dashboard in the owner's list and totals. Other users still do not see it, because it only matches `io.github.<their-user>.*`.

## 0.1.2 — 2026-09-10

- Settings toggles for which totals appear on the bar: count, views, copies, hearts, stars.

## 0.1.1 — 2026-09-10

- In-popup settings page (gear or `s`) to pin the GitHub user.
- The field defaults to the guessed username from installed plugins; blank + save returns to auto-detect.

## 0.1.0 — 2026-09-10

- Bar pill with owned-plugin count and compact view total.
- Popup lists your marketplace plugins with views, copies, hearts, stars, and verification.
- Owner is auto-detected from installed `io.github.<user>.*` plugins; override with `githubUser`.
- Unlisted local plugins still appear, without inventing marketplace stats.
- Reads the public catalog and `/v1/stats` only. Nothing about you is sent.
