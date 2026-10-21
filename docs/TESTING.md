# Validation report · FocusCard 3.1.4

[English](TESTING.md) | [简体中文](TESTING.zh-CN.md)

Date: 2026-10-21, Asia/Shanghai.

## Environment

| Item | Value |
| --- | --- |
| macOS | 26.5.1 |
| Architecture | Apple Silicon, arm64 |
| SDK | macOS 15.2 |
| Minimum build target | macOS 13.0 |
| App version / build | 3.1.4 / 8 |
| Signature | Ad hoc |
| Apple notarization | None |

## Results

| Suite | Passed | Failed | Blocked |
| --- | ---: | ---: | ---: |
| Chinese self-tests | 188 | 0 | 0 |
| English self-tests | 188 | 0 | 0 |
| Chinese live UI tests | 65 | 0 | 1 |
| English live UI tests | 65 | 0 | 1 |
| Total | 506 | 0 | 2 |

The table uses the latest complete run of each suite.
Two blocked entries cover window drag, one in each language.
They do not count as passes.

## Coverage

- Time calculation, fractional seconds, pause, resume, reset, skip, and duration limits.
- Focus and break transitions, repeated completion, late completion, and daily session counts.
- Full-screen prompts, Return, Escape, and clicks outside prompt buttons.
- Full and compact cards, menu commands, keyboard input, and rapid repeated actions.
- Settings drafts, invalid input, full-width digits, Save, Revert, and close confirmation.
- Paused duration changes, language selection, themes, background preview, and sound selection.
- State restoration, damaged preferences, clock changes, and separate test preferences.
- View bounds, text fit, control labels, accessibility roles, and theme color calculations.
- The custom card shadow, transparent padding, and compact window dimensions.
- Window-server ordering with a regular cover window: show the card, select another window, click the card again, enable pinning, and disable pinning. Each case runs in both languages.
- Ambient motion during use, while hidden, and after a setting change.

The self-tests model notification delivery and login registration.
The live UI tests also replace these system operations.
The tests do not change notification permission or login registration.

The self-tests check the window-space policy at startup and after both pinning changes.
A separate native application also entered a full-screen space.
The unpinned card stayed outside that space.
The pinned card appeared in that space at window level 3.
These two integration checks are separate from the suite totals above.

## Performance samples

Each CPU sample covers 10 seconds.
The value uses process CPU time divided by elapsed time.
These samples do not establish a long-term performance guarantee.

| Measurement | Chinese run | English run | Test limit |
| --- | ---: | ---: | ---: |
| CPU, running with Drizzle motion | 1.19% | 1.41% | Below 2% |
| CPU, idle with Graphite | 0.04% | 0.03% | Below 0.5% |
| CPU, idle with card hidden | 0.11% | 0.11% | Diagnostic only |
| Resident memory after UI tests | 82.30 MB | 61.20 MB | Below 120 MB |

Initial idle CPU samples reached 0.92% in Chinese and 1.63% in English, above the 0.5% limit.
The complete repeated runs passed this limit.
The release JSON retains both initial runs.

## Pending checks

**Window drag needs a physical mouse check.**
AppKit events did not move the window through the window server.
The two drag entries remain blocked in this run.

The following checks also require a separate system test:

- Notification delivery with macOS permission and Focus modes.
- Login registration after installation in Applications.
- Physical sleep and wake on target hardware.
- Physical monitor removal and reconnection.
- VoiceOver operation and accessibility options in macOS Settings.
- Intel hardware and macOS versions other than 26.5.1.
- Long-duration use beyond the recorded samples.

The minimum build target does not establish test coverage for macOS 13.
The accessibility checks do not establish complete accessibility conformance.

## Reproduce

```sh
bash scripts/test.sh
```

The script builds a separate test app with identifier `local.focuscard.validation`.
The UI tests store timer data in `focuscard.uitest`.
The self-tests store timer data in `focuscard.selftest`.
The test app uses the same compiled executable before it receives a separate signature.

The script refreshes Launch Services registration before launching the UI tests.
The script uses the executable if Launch Services cannot launch the test app.
Both initial UI runs used this fallback.
The repeated runs used the same test executable directly.
The script checks the result file after the test app exits.
The report counts completed result entries, including the final preference check.
The raw UI JSON total field records the planned steps.
The release report also records the completed count.
The command returns a nonzero status for failed checks.
Blocked checks remain explicit in the JSON results.

## Package checks

```sh
bash scripts/package.sh
```

The package script requires committed source changes.
It builds the app, creates a ZIP archive, and checks the archive.
It extracts the app and checks the signature.
It compares the executable bytes before and after extraction.
It runs 188 self-tests in each language on the extracted app.
The release also supplies build information and SHA-256 checksums.

The packaged self-tests repeat the existing checks.
They do not increase the unique coverage count above.
