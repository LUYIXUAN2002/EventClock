import Darwin
import Foundation

/// Injectable time source.
///
/// `now` is wall-clock time suitable for persistence and presentation.
/// `monotonicTime` is seconds that never move backwards and are unaffected by
/// user or network wall-clock changes; it is only valid within one process
/// lifetime and must never be persisted as an absolute value.
public protocol Clock: Sendable {
    var now: Date { get }
    var monotonicTime: TimeInterval { get }
}

/// Production clock.
///
/// Uses Darwin `CLOCK_MONOTONIC`, which continues to advance while the device
/// sleeps and is unaffected by wall-clock changes. It still resets when the
/// device restarts, which is why it is never persisted.
public struct SystemClock: Clock {
    public init() {}

    public var now: Date { Date() }

    public var monotonicTime: TimeInterval {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
    }
}
