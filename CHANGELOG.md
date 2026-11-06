# Changelog

EventClock uses Dota-style user-facing versions (`MAJOR.MINORREVISION` plus a
phase letter). Apple distribution metadata stays numeric. Earlier releases are
summarized here; detailed release notes are kept under `docs/releases/`.

## v1.02B — Circular Time Selection Wheels

**Status: validated on iPhone.** Technical build 6.

- Added shared native-looking duration wheels for presets, automation timer
  actions, and relative-event timers.
- Minutes and seconds wrap continuously in both directions; hours stay bounded
  to 0–24.
- Fixed seconds remaining at a virtual edge when its value was 00, preventing
  backward wrapping.
- Preserved native haptics and VoiceOver behavior via a lightweight
  `UIPickerView` adapter.
- 71 automated tests passing; simulator and device SDK builds succeeded.
- Physical validation confirmed both-direction wrapping, saved `01:59:59`,
  duration boundaries, all supported editors, and existing data preservation.

## v1.02A — External Reset Times and Usage Recovery

**Status: validated on iPhone.** Technical build 5.

- Added user-supplied recovery timers with exact future deadlines, live
  countdowns, edit/reschedule, cancel, and independent notifications.
- Added multiple simultaneous recovery timers and a 15-second test.
- Added relative-event countdowns using the existing event ledger.
- Preserved v1.01C data and added optional timer-kind migration.
- 63 automated tests passing; simulator and device SDK builds succeeded.

## v1.01C — Configurable Events and Rule-Based Automation

**Status: validated on iPhone.** Technical build 4.

- Added typed events, nested AND/OR/NOT automation rules, cooldowns, state
  flags, safe timer/notification/flag actions, and daily/weekly reminders.
- 49 automated tests at release; post-release audit added truth-table coverage
  for a 53-test audit suite.
- Simulator and device SDK builds succeeded.

## v1.01B — Custom Timers and Reusable Presets

**Status: validated on iPhone.** Technical build 3.

- Added named timer presets, duration validation, edit/delete, repeated
  activation, one-off timers, and a 30-second test timer.
- 30 automated tests passing; both SDK builds succeeded.

## v1.01A — Multiple Independent Timers

**Status: validated on iPhone.** Technical build 2.

- Added concurrent timers, per-timer deadlines/cancellation, and per-instance
  notifications.
- 22 automated tests passing; both SDK builds succeeded.

## v1.00 — Initial iPhone Vertical Slice

**Status: validated on iPhone.** Technical build 1.

- Added the EventClockCore timing engine, water-boiling timer, persistence,
  restart recovery, and an initial SwiftUI iPhone app.
- 17 automated tests passing.
