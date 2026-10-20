/// Wait for both catalogs and progress to settle before revealing Home. A short
/// quiet interval absorbs debounced progress rebuilds; the deadline is absolute,
/// so repeated sync notifications cannot keep extending startup.
struct TVHomeStartupGate {
    static let maximumWait: Double = 8
    static let settleInterval: Double = 0.5
    private var readySince: Double?
    private(set) var isReleased = false

    mutating func update(elapsed: Double, isReady: Bool) -> Bool {
        guard !isReleased else { return true }
        if isReady {
            if readySince == nil { readySince = elapsed }
        } else {
            readySince = nil
        }
        isReleased = elapsed >= Self.maximumWait
            || readySince.map { elapsed - $0 >= Self.settleInterval } == true
        return isReleased
    }
}
