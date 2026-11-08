# Release verification

Run the automated gate from any directory, after all phases are integrated:

```sh
script="$PWD/Scripts/verify-release.sh"; (cd / && "$script")
```

## Observed automated evidence — 2026-11-08

Environment: Apple Silicon (arm64), macOS 27.2 (26B123), Xcode 27.2
(27B52). Current working tree based on `f8039e4`; these results cover local,
uncommitted implementation changes. Debug macOS destination; code signing disabled.
The timeouts below were applied individually by the command runner, not as one
cumulative timeout. No test filters or skipped suites were used.

| Command | Timeout | Observed result |
| --- | --- | --- |
| `swift test` | 180 s | PASS: 135 tests in 13 suites; 55.939 s test run |
| `xcodebuild -project UurtjeFactuurtje.xcodeproj -scheme UurtjeFactuurtje -configuration Debug -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO` | 240 s | PASS: 33 tests in 5 suites; 8.217 s test run |
| `Scripts/verify-release.sh` | 360 s | PASS: package 135/13 (55.241 s), unsigned app build, hosted 33/5 (7.987 s), and all three plist/entitlement/project lint checks |

Hosted counts from the successful release gate's `.xcresult` test tree (all passed,
zero failures, zero skipped tests):

| Suite | Executed tests |
| --- | ---: |
| TrackPresentationTests | 6 |
| EditorFlowTests | 7 |
| ReportsPresentationTests | 10 |
| NativeHostTests | 8 |
| MenuBarStatusTests | 2 |

The existing changed hosted report-label assertion compiled and executed. Added
regressions cover quit-time rejection of direct editor, timer, Undo and preference
callbacks while accepted FIFO work drains; rejection during asynchronous quit
confirmation; cancellation/recovery of submission and matched sleep/wake delivery.
Package regressions cover both Lord Howe 30-minute DST transitions through custom
and day bounds, week cells/totals and project drilldown clipping. The known-ended
pending-sleep test still asserts ordinary rename rejection (`recoveryRequired`).

Local evidence (temporary logs are not portable release artifacts):

- `/tmp/uurtjefactuurtje-swift-test-final.log`
- `/tmp/uurtjefactuurtje-hosted-tests-final.log`
- `/tmp/uurtjefactuurtje-verify-release-final.log`
- `/tmp/uurtjefactuurtje-hosted-test-tree.json`
- Release gate result bundle:
  `/Users/wichert/Library/Developer/Xcode/DerivedData/UurtjeFactuurtje-bjyznlajovolhndjqthluvhvvqnp/Logs/Test/Test-UurtjeFactuurtje-2026.11.08_12-58-11-+0100.xcresult`

### Earlier failures and timeout diagnosis

The first package run exposed an incorrect new test expectation: the minute after
Sunday's end lies outside the week. The corrected test asserts exact week bounds
and clipping, not a looser duration. The first executing hosted run exposed an
incorrect new test assumption: matched wake creates a new owned timer. The test
now asserts its new identity, task, checkpoint and the original entry's sleep end.

An initial standalone hosted command (240 s limit) compiled but timed out before
any tests executed. Sampling its orphaned app showed the main thread repeatedly
rebuilding SwiftUI commands: command evaluation reinstalled observable scene-action
closures. Marking those callback storage properties `@ObservationIgnored` removed
the feedback loop. Only that invocation's orphaned app was terminated; an older,
unrelated package-test helper was left alone. Subsequent hosted runs executed all
five suites. Diagnostic log: `/tmp/uurtjefactuurtje-hosted-tests.log`; sample:
`/tmp/uurtjefactuurtje-hosted-timeout.sample.txt`.

Xcode logged `com.apple.linkd.autoShortcut` connection warnings in successful
hosted runs; they did not prevent execution. Notification delivery is still a
manual check below. Automated success is not signed-distribution or full product
acceptance evidence.

## Unverified manual acceptance and release gates

All boxes below intentionally remain unchecked: these checks were not observed.

### Acceptance a1

- [ ] Exercise the finished application end to end and review its implemented behavior against the intended application requirements, confirming that no required implementation remains unfinished.

### Track, editing and reports

- [ ] Create/edit/archive/restore projects and nested tasks; exercise migration/Create & Start, guarded migration/correction/review Undo, stale drafts and explicit currency consent.
- [ ] Check ambiguous/nonexistent wall times, all conflict adjustments, unknown sleep/interrupted review and stop/re-preview; cancel without writing and confirm failed saves retain drafts/evidence.
- [ ] Check zero-cell drilldown, Back, archive filters, weekday/time-zone/DST changes, lifetime versus period labels and provisional versus confirmed amounts. Switch Track/Reports and reopen windows to assess report navigation-state lifetime.
- [ ] Check keyboard-only and VoiceOver navigation; narrow windows, light/dark, reduced motion, focus restoration and copyable failure details.

### Native lifecycle

- [ ] Close all workspace windows: status elapsed time/checkpointing and menu routes continue. Rapidly mix menu/editor/settings/Undo actions.
- [ ] Quit with queued editor/settings work and running/paused/restored/pending time; exercise confirmation cancellation, stop failure, close failure, duplicate termination and explicit reopen without replay.
- [ ] Perform physical repeated sleep/wake, including notifications during quit/drain; verify no invented billable gap or automatic restored continuation. Force termination and verify checkpoint-based recovery.
- [ ] Test notification permission denied/granted, Focus, combined warning content and click routing.

### Signed distribution and durability

- [ ] Produce a signed archive/export and launch it; inspect the actual sandbox container, stable identity and hardened runtime without relaxing entitlements to make tests pass.
- [ ] Exercise hardware power-loss and real Arq/Time Machine/APFS restoration; verify complete generations and preserved evidence, not merely process-crash simulation.

No automated blocker remains in the commands above. These unchecked manual,
signed-distribution and real-durability gates still block claiming full release
readiness. No workflow history or historical validation report was updated.
