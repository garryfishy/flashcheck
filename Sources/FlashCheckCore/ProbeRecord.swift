public struct ProbeRecord: Codable, Sendable {
    public let sequence: Int
    public let sessionID: String
    public let offset: UInt64
    public let length: Int
    public let kind: BlockKind
    public let generation: UInt32
    public var writeError: IOError?
    public var syncError: IOError?
    public var reads: [ReadObservation]

    var isGood: Bool {
        writeError == nil && syncError == nil && reads.count == 2 && reads.allSatisfy { $0.verification == .match }
    }

    public init(sequence: Int, sessionID: String, offset: UInt64, length: Int, kind: BlockKind, generation: UInt32, writeError: IOError? = nil, syncError: IOError? = nil, reads: [ReadObservation] = []) {
        self.sequence = sequence; self.sessionID = sessionID; self.offset = offset; self.length = length
        self.kind = kind; self.generation = generation; self.writeError = writeError; self.syncError = syncError; self.reads = reads
    }
}

public struct ReadObservation: Codable, Sendable {
    public let error: IOError?
    public let verification: Verification?
    public init(error: IOError?, verification: Verification?) { self.error = error; self.verification = verification }
}
