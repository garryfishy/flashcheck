public struct Layout: Sendable {
    public static let unit: UInt64 = 65_536
    public let evictBytes: UInt64
    public var aliasBases: Range<UInt64> { 1 * 1024 * 1024 ..< 9 * 1024 * 1024 }
    public var filler: Range<UInt64> { 9 * 1024 * 1024 ..< 9 * 1024 * 1024 + evictBytes }
    public static let minCandidate: UInt64 = 512 * 1024 * 1024
    public static let minDeviceSize: UInt64 = 1024 * 1024 * 1024

    public init(evictBytes: UInt64) {
        precondition(evictBytes <= 256 * 1024 * 1024 && evictBytes % Self.unit == 0)
        self.evictBytes = evictBytes
    }
}
