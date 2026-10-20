# FocusCard · 专注卡片

[English](README.md) | [简体中文](README.zh-CN.md)

A macOS timer with a translucent card and a menu bar countdown.
The app uses Objective-C and AppKit.
The app interface uses Simplified Chinese.

<p align="center">
  <img src="assets/icon.png" width="112" alt="FocusCard hourglass icon">
</p>

## Screenshots

These images show the app on macOS.
The screenshots include only the app windows.

| Focus | Break |
| --- | --- |
| ![Focus card with 25 minutes](docs/screenshots/focus.png) | ![Break card with 5 minutes](docs/screenshots/break.png) |

<details>
<summary>Settings</summary>

![Settings for duration, notifications, and appearance](docs/screenshots/settings.png)

</details>

## Features

- Read the remaining time in the menu bar.
- Set focus and break durations from 1 to 180 minutes.
- Pause, continue, or reset the current timer.
- Select automatic transitions between focus and break.
- Receive a system notification when a phase ends.
- Select a separate sound alert.
- Adjust the translucent background.
- Keep the card above other windows.
- Restore the timer and card position when you open the app again.

The default focus duration is 25 minutes.
The default break duration is 5 minutes.
A completed focus phase starts a break automatically.
A completed break phase waits for you to start the next focus phase.
You can change both transition settings.

## Requirements

- macOS 13 or later is the minimum build target.
- Xcode Command Line Tools supply the compiler.
- The build uses the Mac's native architecture.
- Validation used Apple Silicon and macOS 26.5.1.

The app has no external runtime dependencies.
The timer works without a network connection.

## Build

1. Install Xcode Command Line Tools if necessary.

   ```sh
   xcode-select --install
   ```

2. Clone this repository.

   ```sh
   git clone https://github.com/hzxwonder/focus-card-macos.git
   ```

3. Enter the repository directory.

   ```sh
   cd focus-card-macos
   ```

4. Build the app.

   ```sh
   bash scripts/build.sh
   ```

5. Open the app.

   ```sh
   open build/FocusCard.app
   ```

The build creates the app bundle and its icons.
The build runs the timer checks.
The build applies an ad hoc signature for local use.
The build does not notarize the app.

## Use

| Control | Action |
| --- | --- |
| Primary button | Start, pause, or continue the timer. |
| Reset button | Restore the full duration of the current phase. |
| Focus or break selector | Select a phase when the timer is ready or paused. |
| Card title | Drag the title to move the card. |
| Settings button | Open the settings window. |
| Menu bar countdown | Open the timer menu. |
| Show card / 显示卡片 | Restore a hidden card. |
| Hide card / 隐藏卡片 | Hide the card and keep the timer active. |
| Space | Control the timer when the card has keyboard focus. |
| Command-comma | Open settings when the app has keyboard focus. |
| Command-Q | Exit the app when the app has keyboard focus. |

A phase change restores the full duration for that phase.
Duration changes apply to the next phase if the current timer started.
Select Reset to apply a duration change to the current phase.
Cancel restores the saved background setting after a preview.

## Notifications

1. Open Settings / 设置.
2. Select system notifications.
3. Save the settings.
4. Allow notifications in macOS.
5. Select Test notification / 测试通知 to check delivery.

The settings window shows the permission state.
If macOS denies permission, the permission button opens macOS settings.
macOS Focus settings can suppress notification banners.
The sound alert uses the Mac's output volume.

The app must remain active to send an alert when a phase ends.
A hidden card does not stop the timer.
Exit stops the app process.

## Timer behavior

The timer stores an end time when you start it.
A pause stores the remaining time.
Sleep time counts toward the current phase.
When the Mac wakes, the app completes an expired phase once.
An automatic transition starts the next phase at that time.
The app does not count multiple phases during sleep.

When you open the app again, it restores the saved phase.
An active timer uses its original end time.
Local preferences store timer settings and card position.
The app does not send timer data to a server.

## Checks

The build runs the checks automatically.
You can also run them directly.

```sh
build/FocusCard.app/Contents/MacOS/FocusCard --self-test
```

The checks cover remaining time, pause, continue, state restoration, phase transitions, duration limits, and countdown formatting.

This command reads notification permission and delivered notifications for this app.

```sh
build/FocusCard.app/Contents/MacOS/FocusCard --notification-status
```

## Files

| Path | Content |
| --- | --- |
| `src/FocusCard.m` | App, timer logic, settings, notifications, and checks. |
| `resources/Info.plist` | App bundle information. |
| `scripts/build.sh` | Local build script. |
| `assets/icon.svg` | Editable hourglass icon. |
| `assets/icon.png` | Icon at 1024 × 1024 pixels. |
| `docs/screenshots/` | App screenshots. |
| `build/` | Local build output. Git excludes this directory. |

## Documentation style

The English instructions follow ASD-STE100 writing principles.
They use short sentences, active voice, and consistent terms.
The Chinese document follows the same structure.
This project does not claim full ASD-STE100 dictionary compliance or certification.
