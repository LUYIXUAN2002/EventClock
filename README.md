# EventClock

EventClock is an event-driven timing, reminder, and automation platform for Apple platforms. It starts countdowns from events and confirmed real-world conditions, rather than requiring every timer to be set manually.

The first application is an iPhone app. The timing engine is a reusable Swift package kept independent of SwiftUI, HealthKit, AlarmKit, and other platform frameworks.

## Current version and validation

**Latest validated release: EventClock v1.02B (technical build 6).**

- Automated validation: **71 tests passing, 0 failures**.
- iOS simulator-SDK and device-SDK builds succeed without signing.
- Physical iPhone acceptance confirmed:
  - Minutes and seconds circular scrolling in both directions.
  - Saved duration `01:59:59` restoring correctly.
  - Duration boundaries `00:00:00`, `24:00:00`, and `24:00:01`.
  - Circular wheels in preset, automation-rule, and relative-event editors.
  - Existing timer, preset, automation, and recovery data preserved.
- No App Store release has been made.

v1.02A remains available as the prior validated release.

## Features

- Multiple concurrent timers with independent cancellation and completion notifications.
- Saved timer presets with custom names and durations, plus one-off timers.
- Circular duration wheels for minutes and seconds with continuous bidirectional wrapping; the hours wheel remains bounded to 0–24.
- The original cooking trigger: a 10-minute timer started by "Water is boiling", with 10-second and 30-second test modes.
- Configurable events with named types, stable IDs, timestamps, and typed payloads.
- Automation rules with:
  - AND, OR, and NOT conditions, including nested groups in the engine.
  - Boolean state flags.
  - Typed payload comparisons.
  - Time-of-day windows.
  - Timer running/not-running predicates.
  - Optional cooldowns.
  - Actions to start presets, start configured timers, send notifications, or set state flags.
- Daily and weekly system reminders.
- Recovery timers for externally supplied reset times:
  - Exact future date and time.
  - Live countdown.
  - Edit/reschedule and cancel.
  - Multiple simultaneous timers.
  - Clearly labeled user-supplied estimates.
- Relative-event countdowns measured from a recorded event.
- Atomic local persistence, relaunch recovery, stable notification IDs, and launch/foreground notification reconciliation.

## Architecture

```text
Sources/EventClockCore/       Deterministic timing and automation engine
  Models.swift                Events, timers, definitions, persistence, effects
  Automation.swift            Typed values, conditions, rules, recurrence
  TimerEngine.swift           Actor-based timer/rule processing and recovery
  Clock.swift                 Injectable wall + monotonic clock
  Store.swift                 Atomic file and in-memory stores
  Scheduling.swift            Advisory wake-up interface

Sources/EventClockPlatform/   Apple notification adapters and wheel arithmetic
  UserNotificationCenterAdapter.swift
  TimerNotificationCoordinator.swift
  RecurringNotificationCoordinator.swift
  CircularWheelMath.swift

App/EventClock/               SwiftUI iPhone application
  DurationWheels.swift        Native UIPickerView-backed circular wheels

Tests/                        Core and notification-platform tests
```

`EventClockCore` imports only Foundation. The app and platform adapters consume engine effects and perform external side effects. UserNotifications APIs stay outside Core.

## Requirements

- macOS with Xcode 27 / Swift 6 toolchain.
- iOS 17 or later for the app.
- No external package dependencies.
- An Apple signing team for physical-device installation.

## Build and test

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

## Testing status

- 71 automated tests: 54 Core, 17 notification-platform, 0 failures.
- iOS simulator-SDK and device-SDK builds succeed without signing.
- Physical iPhone acceptance for v1.02B is complete.
- Continuous background execution is not available on iOS: recurring reminders and notifications are system-scheduled, and the rule engine runs only when the app processes an event.
- iOS notification delivery is controlled by iOS and is not guaranteed.

## Screenshots

Approved screenshots are not yet available. Planned placeholders:

- Timer dashboard
- Recovery timers
- Automations and state flags

## Known limitations

- Reset times are manually supplied estimates. EventClock does not access service accounts, private usage limits, or reset APIs; it does not scrape websites or request API keys.
- No continuous background rule engine. Rules run when the app processes an event.
- No HealthKit, AlarmKit, watchOS, or real sensor integrations yet.
- The current rule editor exposes one flat AND/OR/NOT group; nested conditions are supported by the engine and preserved, but not fully authorable in the UI.
- Notification delivery and alarm behavior are not guaranteed by iOS.
- The UI shows the five most recent terminal timers; older timers remain persisted.
- No exactly-once external side effects or event journal/outbox.
- Corrupt persisted state surfaces an error rather than self-healing.
- No license has been selected for this project yet.

## Roadmap

- Authorized service APIs and Shortcuts-based reset triggers.
- Sleep-goal alarms using authorized wearable data, with clear latency and background limitations.
- Cooking and environmental sensor integrations.
- AlarmKit-backed critical alerts where supported.
- Apple Watch companion experience.
- Expanded rule authoring, including nested conditions and additional event sources.

## Versioning and history

EventClock uses Dota-style user-facing versions such as `1.02B`. Apple-facing metadata remains numeric. See [CHANGELOG.md](CHANGELOG.md) for release history and [release notes](docs/releases/v1.02B.md).

## License

No license has been selected. Do not redistribute or publish this source until a license decision is made.

---

EventClock is not affiliated with or endorsed by OpenAI, Anthropic, DeepSeek, or any external service mentioned by users.
