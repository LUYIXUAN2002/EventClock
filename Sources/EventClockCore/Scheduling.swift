import Foundation

/// Advisory hook for a host that wants to be woken near a timer deadline.
///
/// The engine remains correct without a scheduler: expiry is always settled
/// by calling `advance()` or by recovery. Implementations must be thread-safe
/// and must not call back into the engine synchronously.
public protocol WakeScheduler: Sendable {
    func schedule(timerID: String, at deadline: Date)
    func cancel(timerID: String)
}

public struct NoopWakeScheduler: WakeScheduler {
    public init() {}
    public func schedule(timerID: String, at deadline: Date) {}
    public func cancel(timerID: String) {}
}
