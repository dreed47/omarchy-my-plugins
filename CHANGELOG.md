# Changelog

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
