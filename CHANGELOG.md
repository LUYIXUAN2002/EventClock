# Changelog

EventClock uses Dota-style versions: `MAJOR.MINORREVISION` plus a phase letter.
Technical build numbers (`CFBundleVersion` / `CURRENT_PROJECT_VERSION`) are
separate from user-facing versions. See README.md for the version rules.

## v1.02A — External Reset Times and Usage Recovery

Status: automated tests passing and iOS app builds succeeded. Physical-device
validation is pending.

### Added

- Absolute recovery timers for externally supplied service reset times with
  service name, exact future deadline, live countdown, status, edit/reschedule,
  cancel, and independent notifications.
- Multiple simultaneous recovery timers persisted across relaunch.
- Relative event countdowns: recording an `Event` starts a timer measured from
  that event's timestamp, using the existing event deduplication ledger.
- Dedicated Recovery screen, a 15-second notification test, and clear
  user-supplied-estimate labeling.
- Optional `TimerKind` metadata (`recovery`, `relativeEvent`) with
  backward-compatible decoding for older timers.
- `.timerUpdated` engine effect and notification replacement for rescheduled
  recovery timers.
- Focused recovery tests for absolute timestamps, relative durations, multiple
  timers, editing/cancellation, invalid/past deadlines, duplicate event IDs,
  persistence, DST, clock changes, and reschedule validation.
- Exhaustive AND/OR/NOT truth-table tests added during the v1.01C audit.

### Changed

- Timers can be tagged as recovery or relative-event without changing their
  existing timing, notification, or persistence behavior.
- User-facing display version updated to `EventClock v1.02A`; Apple-facing
  `CFBundleShortVersionString` remains numeric `1.1.0`, technical build is `5`.

### Tests

- 63 automated tests total: 54 core and 9 notification-platform tests,
  0 failures.
- iPhone app builds succeeded for simulator and device SDKs without signing.
  No physical-device validation was performed for this version.

## v1.01C — M2C: Configurable Events and Rule-Based Automation

Status: validated on a physical iPhone by the product owner, including event
matching and rule execution, enabled/disabled rules, cooldown enforcement,
single state-flag behavior, multiple rules responding to one event, automation
timer creation, notification delivery, and two TRUE state-flag conditions.

### Post-release audit

- Added exhaustive AND/OR/NOT and nested truth-table tests.
- Audit suite: 53 automated tests (44 core + 9 platform), 0 failures.
- Persistence, cooldown recovery, and duplicate-event suppression rechecked.
- Device-SDK build succeeded; `v1.01C` tag and numeric metadata confirmed.

### Added

- Typed `EventValue` payloads (text, number, boolean) on named, timestamped
  events with stable IDs; manual and simulated sensor event sources.
- `AutomationRule` with trigger, nested AND/OR/NOT conditions, one action,
  enabled state, timed cooldown, and persisted configuration.
- Predicates for boolean state flags, typed payload comparisons, local
  time-of-day windows including midnight wrapping, and timer running state.
- Actions that start a saved preset, start a configured timer, request an
  immediate notification, or set a state flag.
- Deterministic pre-action state snapshots so one rule's action cannot alter
  another rule's condition for the same event.
- Automations UI: rule list, enable/disable, create/edit/delete, condition
  builder, synthetic event sender with payloads, result reporting, state flag
  toggles, and daily/weekly reminders.
- Persisted state flags, rule cooldowns, and recurring reminders.
- System-scheduled daily/weekly reminder notifications using repeating calendar
  triggers; documented as notification delivery, not background rule execution.
- Immediate rule notification scheduling and recurring reminder reconciliation
  in EventClockPlatform.

### Changed

- `Event` payloads now use `[String: EventValue]`; events are provider-neutral.
- Persisted snapshots include automation rules, state flags, cooldown
  timestamps, and recurring reminders, with defaults for older data.
- Running timers produced by rules remain independent of later rule edits or
  deletion.
- User-facing display version updated to `EventClock v1.01C`; Apple-facing
  `CFBundleShortVersionString` remains numeric `1.1.0`, technical build is `4`.

### Tests

- 49 automated tests total: 40 core and 9 notification-platform tests,
  0 failures.
- New coverage: event matching, nested AND/OR/NOT, true/false conditions,
  multiple responding rules, disabled rules, cooldown boundaries and
  persistence, duplicate event IDs versus identical payloads, action
  independence and failure, rule persistence, v1.01B migration, invalid and
  deeply nested rules, unsupported operators, time-of-day/time-zone boundaries,
  daily/weekly recurrence across DST, immediate notifications, and recurring
  reminder reconciliation/cancellation.
- iPhone app builds succeeded for simulator and device SDKs without signing.
  Physical-device validation was later confirmed by the product owner.

## v1.01B — M2B: Custom Timers and Reusable Presets

Status: validated on a physical iPhone by the product owner, including preset
creation/editing/deletion, repeated activations, running-timer independence,
one-off timers, persistence, notifications, and invalid-input rejection.

### Added

- `TimerDefinition` in EventClockCore: stable identifier, name, duration,
  manual trigger descriptor, enabled flag, and action configuration.
- Persisted user-defined presets with create, edit, delete, and repeated
  activation in the iPhone app.
- Hours/minutes/seconds duration editor with validation from 1 second through
  24 hours and names of 1–60 trimmed characters.
- One-off timers that are started without being saved as presets.
- Per-preset activation with duplicate event-ID suppression.

### Changed

- Persisted snapshots now include definitions while remaining compatible with
  v1.01A state that has no definitions key.
- Running timers snapshot their definition's name, duration, and actions, so
  editing or deleting a preset cannot alter existing instances.
- User-facing display version updated to `EventClock v1.01B`; Apple-facing
  `CFBundleShortVersionString` is the numeric `1.1.0`, technical build is `3`.

### Tests

- 30 automated tests total: 23 core and 7 notification-platform tests,
  0 failures.
- New coverage: preset create/edit/delete, definition persistence, duration and
  name validation, multiple activations of one preset, editing/deleting a
  running preset, duplicate-event suppression, one-off timers, disabled
  definitions, and v1.01A state migration.
- iPhone app builds succeeded for simulator and device SDKs without signing.
  Physical-device validation was later confirmed by the product owner.

## v1.01A — M2A: Multiple Independent Timers

Status: validated on a physical iPhone by the product owner, including
simultaneous timers, completion notifications, independent cancellation,
multiple instances of one timer, and persistence/recovery after termination.

### Added

- Concurrent timer support with unique, persisted timer identifiers.
- Active timer list ordered by nearest deadline, with remaining time derived
  from each engine deadline.
- Per-timer cancellation controls that do not affect other timers.
- A 30-second custom test timer alongside the 10-minute boiling-water and
  10-second test triggers.
- Recent list for finished and cancelled timers while retaining full persisted
  terminal state.
- Centralized version display (`EventClock v1.01A`) and a separate build number.

### Changed

- Starting a timer no longer blocks other timers from running.
- Each timer schedules and reconciles its own local notification using a
  stable per-instance identifier.
- Notification scheduling errors are reported without rolling back persisted
  timer state.

### Tests

- 22 automated tests total: 15 core and 7 notification-platform tests,
  0 failures.
- New coverage: two concurrent timers with different durations, independent
  expiry and cancellation, multi-timer persistence/recovery and terminal-state
  persistence, duplicate-versus-repeated events, and independent notification
  scheduling/cancellation.
- iPhone app builds succeeded for both simulator and device SDKs without
  signing. No physical-device validation was performed for this version.

## v1.00 — M1: iPhone Vertical Slice

Status: validated on a physical iPhone by the product owner, including
installation/launch, timer completion notification delivery (also received on
Apple Watch), cancellation without a completion alert, and relaunch recovery.

### Added

- SwiftUI iPhone app connected to the local EventClockCore package.
- Water-boiling trigger, 10-minute countdown, cancel, and 10-second test mode.
- Immediately scheduled UserNotifications request with stable timer identifiers.
- Launch/foreground reconciliation of pending notifications.
- Foreground notification presentation and permission-denied explanation.
- Atomic file persistence and restart recovery.

### Tests

- 17 automated tests total: 11 core and 6 notification-platform tests,
  0 failures.
- Physical-device validation was confirmed separately by the product owner.
