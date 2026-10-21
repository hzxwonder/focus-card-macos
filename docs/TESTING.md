# Validation report · FocusCard 3.1.3

[English](TESTING.md) | [简体中文](TESTING.zh-CN.md)

Date: 2026-10-21, Asia/Shanghai.

## Environment

| Item | Value |
| --- | --- |
| macOS | 26.5.1 |
| Architecture | Apple Silicon, arm64 |
| SDK | macOS 15.2 |
| Minimum build target | macOS 13.0 |
| App version / build | 3.1.3 / 7 |
| Signature | Ad hoc |
| Apple notarization | None |

## Results

| Suite | Passed | Failed | Blocked |
| --- | ---: | ---: | ---: |
| Chinese self-tests | 185 | 0 | 0 |
| English self-tests | 185 | 0 | 0 |
| Chinese live UI tests | 63 | 0 | 3 |
| English live UI tests | 63 | 0 | 3 |
| Total | 496 | 0 | 6 |

The six blocked entries cover window drag, Command-W on the card, and Command-W on Settings in both languages.
The keyboard checks need the test app to retain foreground focus.
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

A separate application window also covered the unpinned card when it activated.
A computer-use click on the card brought the card above that window again.
Window-server metadata confirmed that both windows used level 0.
This check does not replace a physical mouse check.

## Performance samples

Each CPU sample covers 10 seconds.
The value uses process CPU time divided by elapsed time.
These samples do not establish a long-term performance guarantee.

| Measurement | Chinese run | English run | Test limit |
| --- | ---: | ---: | ---: |
| CPU, running with Drizzle motion | 1.05% | 1.24% | Below 2% |
| CPU, idle with Graphite | 0.03% | 0.03% | Below 0.5% |
| CPU, idle with card hidden | 0.13% | 0.09% | Diagnostic only |
| Resident memory after UI tests | 77.9 MB | 53.0 MB | Below 120 MB |

## Pending checks

**Window drag needs a physical mouse check.**
AppKit events did not move the window through the window server.
The two drag entries remain blocked in this run.
The foreground keyboard-close checks also need a manual check.

The following checks also require a separate system test:

- Notification delivery with macOS permission and Focus modes.
- Login registration after installation in Applications.
- Physical sleep and wake on target hardware.
- Physical monitor removal and reconnection.
- VoiceOver operation and the system accessibility display settings.
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
The script uses the executable if Launch Services cannot start the test app. Both recorded UI runs used this fallback.
The script checks the result file after the test app exits.
The report counts completed result entries, including the final preference check.
The raw UI JSON total field records the planned steps; the release report also records the completed count.
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
It runs 185 self-tests in each language on the extracted app.
The release also supplies build information and SHA-256 checksums.

The packaged self-tests repeat the existing checks.
They do not increase the unique coverage count above.
