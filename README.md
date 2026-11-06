# EventClock

EventClock is an event-driven timing, reminder, and automation platform for Apple platforms. It starts countdowns from events and confirmed conditions instead of requiring every timer to be configured manually.

The current application is an iPhone app built with SwiftUI. The timing engine is a reusable Swift package kept independent of SwiftUI, HealthKit, AlarmKit, and other platform frameworks.

## Engineering highlights

- **Swift 6 concurrency:** the timer engine is an actor; all state transitions are serialized, with `Sendable` engine effects and injected time/scheduling boundaries.
- **Reusable Swift package:** `EventClockCore` has no UI, HealthKit, AlarmKit, or UserNotifications dependency. `EventClockPlatform` adapts Apple notifications; the SwiftUI app stays thin.
- **Deterministic timer state machine:** start, update, cancel, expire, and restart recovery for multiple concurrent timers.
- **Correct time handling:** monotonic elapsed time in-process, persisted wall-clock deadlines for recovery, clock-change rebasing, and reboot-safe restart behavior.
- **Persistence and event deduplication:** atomic local snapshots, backward-compatible migrations, duplicate-event suppression, and restored timer state after relaunch.
- **Rule-based automation:** typed event payloads, nested AND/OR/NOT conditions, state flags, cooldowns, and safe actions evaluated against one consistent pre-action snapshot.
- **Notification engineering:** per-instance stable IDs, early scheduling at timer start, cancellation, launch/foreground reconciliation, and system recurring reminders.
- **Native circular UI:** minutes and seconds wrap continuously using a lightweight `UIPickerView` adapter with virtual cyclic rows, native haptics, and VoiceOver support.

## Current release and validation

**Latest validated release: EventClock v1.02B (technical build 6).**

- **71 automated tests, 0 failures** — 54 Core and 17 notification-platform tests.
- iOS simulator-SDK and device-SDK builds succeed without signing.
- Physical iPhone acceptance confirmed:
  - Minutes and seconds circular scrolling in both directions.
  - Saved duration `01:59:59` restoring correctly.
  - Duration boundaries `00:00:00`, `24:00:00`, and `24:00:01`.
  - Circular wheels in preset, automation-rule, and relative-event editors.
  - Existing timer, preset, automation, and recovery data preserved.
- v1.02A remains available as the prior validated release.
- No App Store release has been made.

## Features

- Multiple concurrent timers with independent cancellation and completion notifications.
- Named timer presets, one-off timers, and native circular duration selection.
- Cooking trigger: a 10-minute timer started by “Water is boiling”, with 10-second and 30-second test modes.
- Typed events with stable IDs, timestamps, and payloads.
- Automation rules with nested conditions, state flags, payload comparisons, time-of-day windows, timer-state predicates, and cooldowns.
- Actions that start saved presets or configured timers, request notifications, or set state flags.
- Daily and weekly system notifications that do not imply background rule execution.
- Recovery timers for user-supplied external reset times, including live countdowns, rescheduling, cancellation, and multiple simultaneous timers.
- Relative-event countdowns measured from a recorded event.
- Atomic persistence, relaunch recovery, and notification reconciliation.

## Architecture

```text
Sources/EventClockCore/       Deterministic timing and automation engine
  Models.swift                Events, timers, definitions, persistence, effects
  Automation.swift            Typed values, conditions, rules, recurrence
  TimerEngine.swift           Actor-based timer/rule processing and recovery
  Clock.swift                 Injectable wall + monotonic clock
  Store.swift                 Atomic file and in-memory stores
  Scheduling.swift            Advisory wake-up interface

Sources/EventClockPlatform/   Apple notification adapters and platform helpers
  UserNotificationCenterAdapter.swift
  TimerNotificationCoordinator.swift
  RecurringNotificationCoordinator.swift
  CircularWheelMath.swift

App/EventClock/               SwiftUI iPhone application
  DurationWheels.swift        Native circular UIPickerView-backed wheels

Tests/                        Core and notification-platform tests
```

`EventClockCore` imports only Foundation. The app and platform adapters consume engine effects and perform external side effects. UserNotifications APIs stay outside Core.

## Requirements and setup

- macOS with Xcode 27 / Swift 6 toolchain.
- iOS 17 or later for the app.
- No external package dependencies.
- An Apple signing team for physical-device installation.

```sh
swift build
swift test
```

Build the app without signing:

```sh
xcodebuild -project App/EventClock.xcodeproj -scheme EventClock \
  -configuration Debug -sdk iphonesimulator \
  -derivedDataPath .build/XcodeDerivedData build CODE_SIGNING_ALLOWED=NO
```

Run on iPhone:

1. Open `App/EventClock.xcodeproj` in Xcode.
2. Select the EventClock target → Signing & Capabilities → choose your team.
3. Connect and trust an iPhone, select it, and run.
4. Allow notifications. Denied permission leaves in-app timers functional but suppresses alerts outside the app.

## Testing

- 71 automated tests: 54 Core, 17 notification-platform, 0 failures.
- Tests cover timer lifecycle, concurrent timers, persistence/recovery, clock changes, event deduplication, rule truth tables, cooldowns, actions, time zones, DST, notification reconciliation, and circular-wheel arithmetic.
- Physical iPhone acceptance for v1.02B is complete.
- iOS controls notification delivery; delivery is not guaranteed.
- iOS does not provide continuous background execution. Recurring reminders and notifications are system-scheduled, and rules run only when the app processes an event.

## Known limitations

- Reset times are manually supplied estimates. EventClock does not access service accounts, private usage limits, or reset APIs; it does not scrape websites or request API keys.
- No continuous background rule engine.
- No HealthKit, AlarmKit, watchOS, or real sensor integrations yet.
- The rule editor exposes one flat AND/OR/NOT group; deeper nesting is supported by the engine and preserved but not fully authorable in the UI.
- Notification delivery and alarm behavior are not guaranteed by iOS.
- The UI shows the five most recent terminal timers; older timers remain persisted.
- No exactly-once external side effects or event journal/outbox.
- Corrupt persisted state surfaces an error rather than self-healing.
- This repository is public, but no reuse or redistribution license has been granted.

## Roadmap

- Authorized service APIs and Shortcuts-based reset triggers.
- Sleep-goal alarms using authorized wearable data, with explicit latency and background limitations.
- Cooking and environmental sensor integrations.
- AlarmKit-backed critical alerts where supported.
- Apple Watch companion experience.
- Expanded rule authoring, including nested conditions and additional event sources.

## Versioning and history

EventClock uses Dota-style user-facing versions such as `1.02B`. Apple-facing metadata remains numeric. See [CHANGELOG.md](CHANGELOG.md) for release summaries and [v1.02B release notes](docs/releases/v1.02B.md).

## License

No open-source or reuse license has been granted. This repository is publicly visible, but no permission is granted to copy, modify, redistribute, or use the source. All rights reserved.

---

EventClock is not affiliated with or endorsed by OpenAI, Anthropic, DeepSeek, or any external service mentioned by users.
