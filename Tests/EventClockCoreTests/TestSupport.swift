import Foundation
import EventClockCore

/// Fully manual clock. Wall clock and monotonic time advance together unless
/// a test changes one independently.
final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Date
    private var monotonic: TimeInterval

    init(
        wall: Date = Date(timeIntervalSince1970: 1_700_000_000),
        monotonic: TimeInterval = 10_000
    ) {
        self.wall = wall
        self.monotonic = monotonic
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return wall
    }

    var monotonicTime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return monotonic
    }

    /// Advances both clocks, simulating the passage of real time.
    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        wall = wall.addingTimeInterval(seconds)
        monotonic += seconds
    }

    /// Moves only the monotonic clock.
    func advanceMonotonic(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        monotonic += seconds
    }

    /// Moves only the wall clock, simulating a user or network clock change.
    func shiftWall(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        wall = wall.addingTimeInterval(seconds)
    }
}

struct RecordedWake: Equatable, Sendable {
    let timerID: String
    let deadline: Date
}

final class RecordingScheduler: WakeScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var wakes: [RecordedWake] = []
    private var cancellations: [String] = []

    var scheduled: [RecordedWake] {
        lock.lock()
        defer { lock.unlock() }
        return wakes
    }

    var cancelled: [String] {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    func schedule(timerID: String, at deadline: Date) {
        lock.lock()
        defer { lock.unlock() }
        wakes.append(RecordedWake(timerID: timerID, deadline: deadline))
    }

    func cancel(timerID: String) {
        lock.lock()
        defer { lock.unlock() }
        cancellations.append(timerID)
    }
}

func makeEngine(
    clock: ManualClock,
    store: any TimerStore = InMemoryTimerStore(),
    scheduler: any WakeScheduler = NoopWakeScheduler(),
    rules: [Rule] = [.waterBoiling],
    calendar: Calendar = .autoupdatingCurrent
) -> TimerEngine {
    TimerEngine(
        store: store,
        clock: clock,
        rules: rules,
        scheduler: scheduler,
        calendar: calendar
    )
}

func waterBoilingEvent(id: String, clock: ManualClock) -> Event {
    Event(id: id, type: EventType.waterBoiling, occurredAt: clock.now)
}

func startedTimers(in effects: [EngineEffect]) -> [TimerInstance] {
    effects.compactMap {
        if case .timerStarted(let timer) = $0 { return timer }
        return nil
    }
}

func firedTimers(in effects: [EngineEffect]) -> [TimerInstance] {
    effects.compactMap {
        if case .timerExpired(let timer) = $0 { return timer }
        return nil
    }
}

func actionRequests(in effects: [EngineEffect]) -> [(timerID: String, action: Action, key: String)] {
    effects.compactMap {
        if case .actionRequested(let timerID, let action, let key) = $0 {
            return (timerID, action, key)
        }
        return nil
    }
}

func automationEvaluations(in effects: [EngineEffect]) -> [AutomationEvaluation] {
    effects.compactMap {
        if case .automationEvaluated(let evaluation) = $0 { return evaluation }
        return nil
    }
}
