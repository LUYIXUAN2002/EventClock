import Foundation

/// Persistence boundary for the engine. M0 stores one atomic snapshot;
/// implementations must provide all-or-nothing replacement semantics.
public protocol TimerStore: Sendable {
    func load() throws -> PersistedState
    func save(_ state: PersistedState) throws
}

/// Atomic JSON file store. Creates the parent directory when needed and writes
/// via `Data.write(options: .atomic)`.
public struct FileTimerStore: TimerStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> PersistedState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return .empty }
        return try JSONDecoder().decode(PersistedState.self, from: data)
    }

    public func save(_ state: PersistedState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// In-memory store for tests and previews.
public final class InMemoryTimerStore: TimerStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PersistedState

    public init(state: PersistedState = .empty) {
        self.state = state
    }

    public func load() throws -> PersistedState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func save(_ newState: PersistedState) throws {
        lock.lock()
        defer { lock.unlock() }
        state = newState
    }
}
