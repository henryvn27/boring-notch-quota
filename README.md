# Notch

![macOS](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple)
![License](https://img.shields.io/badge/license-GPLv3-blue)

**Notch is a community fork of [Boring Notch](https://github.com/TheBoredTeam/boring.notch).**
It keeps the upstream app's notch, windowing, settings, gestures, and integrations,
then builds focused Codex quota and local-cost features on top. It is not an
official Boring Notch release or a replacement for the upstream project.

The upstream project and its contributors deserve the credit for the foundation
that makes this fork possible. See [UPSTREAM.md](UPSTREAM.md) for the scope of
the fork, the original project, and the attribution boundary.

## What this fork adds

Notch adds a native **Codex** tab beside Home and Shelf. It keeps quota
information easy to scan without pulling in task names, agent activity,
approvals, or hooks.

- 5-hour and weekly windows with remaining percentage and a proportional usage meter.
- A pace comparison showing whether usage is ahead of or behind the time left in the reset window.
- Reset timing and a plain-language “runs out” estimate.
- A read-only API-price equivalent based on local Codex session logs, with in-notch daily and model breakdowns.
- An unofficial reset forecast, clearly marked as third-party information.
- Freshness, partial-data, and estimate-only labels so the display never pretends to be a bill or an official forecast.

This fork deliberately does **not** install Codex hooks, observe task activity,
capture prompts, or show agent progress. Official quota data comes from the
local Codex app-server; local cost data is read-only and bounded. The cost
scanner is self-contained in Notch and does not require CodexBar or any other
separately installed usage monitor.

## Install

The first public build is source/CI based. Once a signed release is available,
the release page will contain the installable DMG:

<https://github.com/henryvn27/notch/releases>

To build locally:

1. Use macOS 14 or later with a current Xcode release.
2. Clone this fork and open `boringNotch.xcodeproj`.
3. Select the `boringNotch` scheme and run it.

```bash
git clone https://github.com/henryvn27/notch.git
cd notch
open boringNotch.xcodeproj
```

The Codex tab needs the local Codex app/CLI to provide official rate-limit
data. If Codex is unavailable, the rest of Notch continues to work and the
tab explains what is unavailable.

## CLI for agents

The repository includes a read-only `the-notch` CLI so Codex and other local
agents can inspect the same quota and pacing signals without opening the app.
It never changes a model, starts work, consumes a reset, or edits Codex
configuration.

Install it without administrator access:

```bash
./scripts/install-the-notch-cli.sh
```

Then use machine-readable output in an agent workflow:

```bash
the-notch status --json --record
the-notch pace --json
the-notch resets --json
the-notch recommend --json
```

`--record` is explicit because it writes a small local history used to
calculate the change in usage deficit over time. Without it, the CLI is
read-only. Banked-reset data is reported as unknown when Codex does not expose
it; unknown is never treated as zero.

An agent can be given this bounded instruction:

> Before long or parallel work, run `the-notch recommend --json`. Use the
> recommendation as context, but do not change the user-selected model,
> concurrency, or reset policy without asking first. Never treat missing or
> stale usage data as permission to spend a reset.

## Privacy boundary

Quota requests stay local to the Codex app-server. The cost estimate scans
local JSONL session records with bounded file and time limits. The reset
forecast is an explicitly labeled third-party HTTPS request. No prompt
contents, task names, or hook payloads are sent by this feature.

## License and attribution

Notch is distributed under the upstream project's GPLv3-compatible terms.
This fork preserves Boring Notch's license and third-party notices and adds
its own changes on top. Read [`UPSTREAM.md`](UPSTREAM.md), [`LICENSE`](LICENSE),
and [`THIRD_PARTY_LICENSES`](THIRD_PARTY_LICENSES) before redistributing a
build.
