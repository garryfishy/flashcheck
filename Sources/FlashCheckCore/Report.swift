import Foundation

public enum Mode: String, Codable, Sendable { case scan, probe, full }
public enum Verdict: String, Codable, Sendable {
    case sampledPassed = "SAMPLED TEST PASSED", fullPassed = "FULL VERIFICATION PASSED"
    case misrepresentation = "CAPACITY MISREPRESENTATION DETECTED", integrityFailure = "STORAGE INTEGRITY FAILURE"
    case inconclusive = "INCONCLUSIVE", testError = "TEST ERROR"
    public var exitCode: Int32 {
        switch self { case .sampledPassed, .fullPassed: 0; case .misrepresentation: 10; case .integrityFailure: 11; case .inconclusive: 12; case .testError: 20 }
    }
}
public struct CapacityFinding: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case established, wrapOnly, lowerBound, undetermined }
    public var kind: Kind; public var reported: UInt64; public var usableLow: UInt64?; public var usableHigh: UInt64?; public var wrapModulus: UInt64?; public var note: String
    public init(kind: Kind, reported: UInt64, usableLow: UInt64? = nil, usableHigh: UInt64? = nil, wrapModulus: UInt64? = nil, note: String) {
        self.kind = kind; self.reported = reported; self.usableLow = usableLow; self.usableHigh = usableHigh; self.wrapModulus = wrapModulus; self.note = note
    }
}
public struct FullResult: Codable, Sendable {
    public var unitsTotal: Int; public var unitsMatched: Int; public var firstBad: UInt64?; public var badRanges: [Range<UInt64>]; public var writeMBps: Double; public var readMBps: Double
    public init(unitsTotal: Int, unitsMatched: Int, firstBad: UInt64?, badRanges: [Range<UInt64>], writeMBps: Double, readMBps: Double) {
        self.unitsTotal = unitsTotal; self.unitsMatched = unitsMatched; self.firstBad = firstBad; self.badRanges = badRanges; self.writeMBps = writeMBps; self.readMBps = readMBps
    }
}
public struct DeviceSummary: Codable, Sendable {
    public var name: String; public var identifier: String; public var reportedSize: UInt64; public var blockSize: Int; public var connection: String
    public init(name: String, identifier: String, reportedSize: UInt64, blockSize: Int, connection: String) { self.name = name; self.identifier = identifier; self.reportedSize = reportedSize; self.blockSize = blockSize; self.connection = connection }
}
public struct Report: Codable, Sendable {
    public var toolVersion: String; public var algorithmVersion: Int; public var mode: Mode; public var sessionID: String
    public var device: DeviceSummary; public var startedAt: Date; public var durationSeconds: Double
    public var bytesWritten: UInt64; public var bytesRead: UInt64
    public var stageA: StageAResult?; public var wrap: WrapResult?; public var boundary: BoundaryResult?; public var full: FullResult?
    public var verdict: Verdict; public var capacity: CapacityFinding; public var errors: [String]
}
