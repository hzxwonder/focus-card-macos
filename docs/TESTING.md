# Validation report · FocusCard 3.1.6

[English](TESTING.md) | [简体中文](TESTING.zh-CN.md)

Date: 2026-10-21, Asia/Shanghai.

## Environment

| Item | Value |
| --- | --- |
| macOS | 26.5.1 |
| Architecture | Apple Silicon, arm64 |
| SDK | macOS 15.2 |
| Minimum build target | macOS 13.0 |
| App version / build | 3.1.6 / 10 |
| Signature | Ad hoc |
| Apple notarization | None |

## Results

| Suite | Passed | Failed | Blocked |
| --- | ---: | ---: | ---: |
| Chinese self-tests | 188 | 0 | 0 |
| English self-tests | 188 | 0 | 0 |
| Chinese live UI tests | 66 | 0 | 3 |
| English live UI tests | 66 | 0 | 3 |
| Total | 508 | 0 | 6 |

The table uses the latest complete run of each suite.
Six blocked entries cover window drag and foreground keyboard-close operations in both languages.
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

The live UI tests open the native status menu from the menu bar button.
They check card restoration, foreground ordering, and the saved window mode.
The test driver places selected windows in the global window order to model foreground clicks.
A separate native fixture checks that the card is in front while the menu is open.
Window-server metadata also placed the card above an independent app while that app remained active.
A computer-use click on the card also closed the menu.
These native integration checks are separate from the suite totals above.

## Performance samples

Each CPU sample covers 10 seconds.
The value uses process CPU time divided by elapsed time.
These samples do not establish a long-term performance guarantee.

| Measurement | Chinese run | English run | Test limit |
| --- | ---: | ---: | ---: |
| CPU, running with Drizzle motion | 1.02% | 0.97% | Below 2% |
| CPU, idle with Graphite | 0.02% | 0.02% | Below 0.5% |
| CPU, idle with card hidden | 0.07% | 0.09% | Diagnostic only |
| Resident memory after UI tests | 103.1 MB | 85.5 MB | Below 120 MB |

## Pending checks

**Window drag needs a physical mouse check.**
AppKit events did not move the window through the window server.
The two drag entries remain blocked in this run.

Cross-application and desktop clicks need physical mouse verification.
The computer-use driver routes clicks to a selected application.
The native fixture cannot post global mouse input without additional system permission.
The test did not change system permissions.

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

Use one UI-test process at a time. The UI suites share one test preferences domain.

The script builds a separate test app with identifier `local.focuscard.validation`.
The UI tests store timer data in `focuscard.uitest`.
The self-tests store timer data in `focuscard.selftest`.
The test app uses the same compiled executable before it receives a separate signature.

The script refreshes Launch Services registration before launching the UI tests.
The script uses the executable if Launch Services cannot launch the test app.
Both recorded UI runs used this fallback.
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
