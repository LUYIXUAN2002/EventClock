import Foundation

/// Pure arithmetic for a cyclic picker wheel with a large virtual row range.
///
/// The UI renders many cycles of the same values so scrolling never reaches a
/// hard edge. The wheel is recentered near the edges without changing the
/// logical value.
public enum CircularWheelMath {
    public static let cycleCount = 1_000
    public static let edgeThreshold = 120

    public static func value(forRow row: Int, modulo: Int) -> Int {
        let modulus = max(1, modulo)
        let remainder = row % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }

    public static func totalRows(modulo: Int) -> Int {
        max(1, modulo) * cycleCount
    }

    public static func initialRow(forValue value: Int, modulo: Int) -> Int {
        let modulus = max(1, modulo)
        let base = modulus * (cycleCount / 2)
        return base + Self.value(forRow: value, modulo: modulus)
    }

    public static func needsRecentering(row: Int, modulo: Int) -> Bool {
        let total = totalRows(modulo: modulo)
        return row < edgeThreshold || row >= total - edgeThreshold
    }

    public static func recenteredRow(forValue value: Int, modulo: Int) -> Int {
        initialRow(forValue: value, modulo: modulo)
    }

    /// A row must be repositioned when it is missing, represents a different
    /// value, or has reached a virtual edge. The edge check is essential even
    /// when the modulo value matches: at physical row 0 the user cannot scroll
    /// backward, even if the logical value (for example, 00 seconds) matches.
    public static func shouldRepositionSelection(
        row: Int,
        value: Int,
        modulo: Int
    ) -> Bool {
        guard row >= 0 else { return true }
        let normalized = Self.value(forRow: value, modulo: modulo)
        let selected = Self.value(forRow: row, modulo: modulo)
        return selected != normalized
            || needsRecentering(row: row, modulo: modulo)
    }
}
