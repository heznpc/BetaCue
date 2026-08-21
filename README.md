# BetaCue

**A personal iOS app-ops dashboard for macOS.** It turns Apple's developer-facing state into
*where you are · what's blocking you · what to do next*, and tells you first when that changes.
Lives in the menu bar.

[![Tests](https://github.com/heznpc/BetaCue/actions/workflows/tests.yml/badge.svg)](https://github.com/heznpc/BetaCue/actions/workflows/tests.yml)

## Why

TestFlight reports its state in three separate places: build processing (`processingState`),
internal distribution (`internalBuildState`), and external distribution (`externalBuildState`).
Apple hands you each field and never tells you what the combination means.

Which is how you end up with **a perfectly valid build that reaches nobody.** The build is
`VALID`, but no beta group is attached to it, so it appears on no device. Nothing anywhere
reports an error. It is easy to miss, and easy to miss for days.

BetaCue reads that combination, states it in one sentence, and notifies you when it changes.

## Design principles

**No LLM in the read path.** Every state decision is deterministic code. Polling, diffing,
blocker detection, next-action selection, notification triggering — zero token cost.

```
App Store Connect API
        ↓  Collector      fan out requests, normalize into one schema
        ↓  RuleEngine     deterministic state resolution
        ↓  StateStore     SQLite — last snapshot and transition log
        ↓  SwiftUI        menu bar + window
```

**"Did the new one land?" and "can testers install right now?" are different questions.**
While the newest build is processing, the previous one usually keeps serving. Collapsing both
into a single state throws that away, so BetaCue resolves them as two separate axes.

**A group existing is not the same as this build being attached to it.** An app can have
groups while the current build reaches nobody — or be distributed through individual invites
or a public link with no group membership at all. So per-build attachments and individual
tester counts are collected separately.

**Never guess.** When Apple returns a value BetaCue doesn't recognize, it resolves to
`UNKNOWN`, shows the raw payload, and hands off to App Store Connect.

**Apple's vocabulary stays out of the main view.** `PROCESSING` becomes "Apple is processing".
Not baby talk either — short declarative phrases. The raw values are one disclosure
triangle away under "Apple details".

## State model

| State | Headline | Next action |
|---|---|---|
| `NO_BUILD` | No build uploaded | — |
| `BUILD_PROCESSING` | Apple is processing | none (wait) |
| `BUILD_INVALID` | Build rejected | open in ASC |
| `BUILD_READY_NOT_DISTRIBUTED` | Reaches nobody | distribute to testers |
| `INTERNAL_TESTING_READY` | Ready to test | — |
| `EXTERNAL_REVIEW_REQUIRED` | Internal testing only | open in ASC |
| `EXTERNAL_REVIEW_PENDING` | In external beta review | none (wait) |
| `EXTERNAL_TESTING_READY` | Internal and external testing | — |
| `ACTION_REQUIRED` | Needs attention | open in ASC |
| `UNKNOWN` | Could not determine state | open in ASC |

States carry a reason code so causes stay distinguishable inside one bucket
(`MISSING_EXPORT_COMPLIANCE`, `EXPIRED`, `BETA_REJECTED`, `NO_GROUPS`, `BUILD_NOT_ASSIGNED`,
`GROUPS_EMPTY`). Transitions are keyed on a `state + reason + build ID` fingerprint rather
than the state ID alone, so a change of cause inside the same bucket still notifies.

## Notifications

Not every change is worth a banner. Only these transitions fire one:

- processing → ready to test
- processing → reaches nobody (the silent-failure case)
- external review → approved
- build rejected
- certificate expiring within 60 days (once per certificate)

The first fetch never notifies, so opening the app for the first time doesn't bury you.

## Polling

One minute while a build is processing, five while anything is in a warning state,
fifteen when everything is quiet. Polling and notifications keep running whether or not
the window has ever been opened.

## Configuration

You need an App Store Connect API key. The key file stays where Apple puts it — BetaCue
only records the path, and never copies or relocates it.

```
~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8
~/.config/betacue/config.json      # Key ID and Issuer ID only
~/Library/Application Support/BetaCue/state.sqlite
```

Only team API keys are supported today. Individual keys sign their JWT with `sub` instead of
`iss`, so they will not authenticate as-is.

## Build

Set `DEVELOPMENT_TEAM` in `project.yml` to your own Apple team ID
(Apple Developer account → Membership).

```bash
xcodegen generate
xcodebuild -project BetaCue.xcodeproj -scheme BetaCue -configuration Debug build
xcodebuild -project BetaCue.xcodeproj -scheme BetaCue test
```

The App Sandbox is disabled because the app reads the key file from your home directory.

## Partial failure

One app failing to load does not stop the others. The failed app keeps its last known
good state and lists what could not be read in its detail view. A status monitor that
halts everything because one endpoint returned 404 is not a status monitor.

## Out of scope for v0

Everything beyond attaching a build to a group: tester CRUD, upload pipeline automation,
certificate provisioning, the full App Store submission flow, AI crash analysis, teams,
accounts, billing. This is a personal tool; those go in when they are actually needed.

`betaTesterUsages` returns 404 in this environment and tester `state` comes back `null`, so
**BetaCue does not claim to know who installed anything.** That stays hidden until the data
is trustworthy.

## Localization

English is the source language; Korean ships in `BetaCue/Localizable.xcstrings`. User-facing
strings go through `String(localized:)`, and the keys are the English text.

Domain values that tests assert on — `Audience`, `RelativeTime.Bucket` — are structured types
with the rendering pushed to a thin layer, so no test depends on which language the process
happens to be running in.

## Tests

Every layer has its failure conditions pinned, because the ones that mattered were all
about what happens when a fetch does not answer.

| Suite | What it holds down |
|---|---|
| `ASCClientTests` | 200/204/4xx decoding, 429 and 5xx retry, the attempt ceiling, pagination, truncation, host validation on `links.next` |
| `CollectorTests` | JSON to `AppSnapshot` — every failed sub-fetch stays `nil` rather than becoming zero, build order survives concurrency, the iOS filter reaches the wire |
| `StoreTests` | single-flight refresh, ID-keyed fallback, first fetch silent, partial data silent, certificate failure isolated, snapshot shown before the network |
| `CommandsTests` | the exact relationship payload, 204 as success, 409 surfaced and never retried, empty selection sends nothing |
| `RuleEngineTests` / `ReliabilityTests` | state resolution and the unknown paths |
| `StateStoreTests` | migration adoption, reason round-trip, prune guarding, an unopenable database |

Requests are answered by a `URLProtocol` stub, so nothing here touches the network. CI runs
the Debug tests and a Release build — optimisation settings have broken builds that were
green in Debug.

## License

MIT — see [LICENSE](LICENSE).
