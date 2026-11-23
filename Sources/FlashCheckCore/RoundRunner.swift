import Darwin
import Foundation

public final class RoundRunner {
    private let device: BlockDevice
    private let pattern: PatternGenerator
    private let layout: Layout
    private let isCancelled: () -> Bool
    private var lastWrites: [UInt64: (kind: BlockKind, generation: UInt32)] = [:]
    private var sequence = 0
    private var evictionRound = 0
    private let sessionID: String
    public private(set) var bytesWritten: UInt64 = 0
    public private(set) var bytesRead: UInt64 = 0
    public private(set) var lastEvictionIncomplete = false
    public private(set) var lastRoundHadNoDecoys = false
    public private(set) var lastSyncError: IOError?
    private var buffer = [UInt8](repeating: 0, count: PatternGenerator.unitSize)

    public init(device: BlockDevice, pattern: PatternGenerator, layout: Layout, isCancelled: @escaping () -> Bool) {
        self.device = device; self.pattern = pattern; self.layout = layout; self.isCancelled = isCancelled
        self.sessionID = pattern.sessionID
    }

    public func round(writes: [(offset: UInt64, kind: BlockKind)], reads: [UInt64], decoysAbove: UInt64?) throws(IOError) -> [ProbeRecord] {
        lastSyncError = nil
        lastEvictionIncomplete = false
        lastRoundHadNoDecoys = false
        var records: [ProbeRecord] = []
        var indices: [UInt64: Int] = [:]
        for write in writes.sorted(by: { $0.offset < $1.offset }) {
            try checkCancelled()
            let old = lastWrites[write.offset]
            let generation = old.map { $0.generation &+ 1 } ?? 0
            lastWrites[write.offset] = (write.kind, generation)
            var record = ProbeRecord(sequence: sequence, sessionID: sessionID, offset: write.offset, length: PatternGenerator.unitSize, kind: write.kind, generation: generation)
            sequence += 1
            buffer.withUnsafeMutableBytes { pattern.fill($0, offset: write.offset, kind: write.kind, generation: generation) }
            do {
                try buffer.withUnsafeBytes { try device.write(at: write.offset, from: $0) }
                bytesWritten += UInt64(buffer.count)
            } catch let error as IOError {
                if isFatal(error) { throw error }
                record.writeError = error
            } catch {
                record.writeError = .writeFailed(errno: EIO)
            }
            indices[write.offset] = records.count
            records.append(record)
        }
        try syncBestEffort(records: &records)
        try evict(excluding: Set(reads), above: decoysAbove ?? writes.map(\.offset).max() ?? 0, records: &records)
        try syncBestEffort(records: &records)
        for offset in reads {
            try checkCancelled()
            guard let written = lastWrites[offset] else {
                records.append(ProbeRecord(sequence: sequence, sessionID: sessionID, offset: offset, length: PatternGenerator.unitSize, kind: .probe, generation: 0, reads: [ReadObservation(error: nil, verification: nil)]))
                sequence += 1
                continue
            }
            let observation = try read(offset: offset, expected: written)
            if let index = indices[offset] { records[index].reads.append(observation) }
            else {
                records.append(ProbeRecord(sequence: sequence, sessionID: sessionID, offset: offset, length: PatternGenerator.unitSize, kind: written.kind, generation: written.generation, reads: [observation]))
                sequence += 1
            }
        }
        return records
    }

    public func reread(_ offsets: [UInt64]) throws(IOError) -> [UInt64: ReadObservation] {
        lastSyncError = nil
        lastEvictionIncomplete = false
        lastRoundHadNoDecoys = false
        var ignored: [ProbeRecord] = []
        try evict(excluding: Set(offsets), above: offsets.max() ?? 0, records: &ignored)
        try syncBestEffort(records: &ignored)
        var observations: [UInt64: ReadObservation] = [:]
        for offset in offsets {
            try checkCancelled()
            if let written = lastWrites[offset] { observations[offset] = try read(offset: offset, expected: written) }
            else { observations[offset] = ReadObservation(error: nil, verification: nil) }
        }
        return observations
    }

    public func preRead(_ offsets: [UInt64]) throws(IOError) -> [UInt64: ReadObservation] {
        var observations: [UInt64: ReadObservation] = [:]
        for offset in offsets {
            try checkCancelled()
            observations[offset] = try read(offset: offset, expected: (.probe, 0))
        }
        return observations
    }

    private func read(offset: UInt64, expected: (kind: BlockKind, generation: UInt32)) throws(IOError) -> ReadObservation {
        do {
            try buffer.withUnsafeMutableBytes { try device.read(at: offset, into: $0) }
            bytesRead += UInt64(buffer.count)
            let verification = buffer.withUnsafeBytes { pattern.verify($0, expectedOffset: offset, kind: expected.kind, generation: expected.generation) }
            return ReadObservation(error: nil, verification: verification)
        } catch let error as IOError {
            if isFatal(error) { throw error }
            return ReadObservation(error: error, verification: nil)
        } catch {
            return ReadObservation(error: .readFailed(errno: EIO), verification: nil)
        }
    }

    private func evict(excluding reads: Set<UInt64>, above: UInt64, records: inout [ProbeRecord]) throws(IOError) {
        evictionRound += 1
        let chunkBytes: UInt64 = 1024 * 1024
        var chunkBase: UInt64 = 0
        while chunkBase < layout.evictBytes {
            try checkCancelled()
            let base = 9 * 1024 * 1024 + chunkBase
            let unitsInChunk = Int(min(chunkBytes, layout.evictBytes - chunkBase) / Layout.unit)
            for unit in 0..<unitsInChunk {
                let offset = base + UInt64(unit) * Layout.unit
                let generation = nextGeneration(offset)
                buffer.withUnsafeMutableBytes { pattern.fill($0, offset: offset, kind: .filler, generation: generation) }
                do {
                    try buffer.withUnsafeBytes { try device.write(at: offset, from: $0) }
                    bytesWritten += UInt64(buffer.count)
                } catch let error as IOError {
                    if isFatal(error) { throw error }
                    lastEvictionIncomplete = true
                    records.append(ProbeRecord(sequence: sequence, sessionID: sessionID, offset: offset, length: buffer.count, kind: .filler, generation: generation, writeError: error))
                    sequence += 1
                    continue
                } catch {
                    lastEvictionIncomplete = true
                    records.append(ProbeRecord(sequence: sequence, sessionID: sessionID, offset: offset, length: buffer.count, kind: .filler, generation: generation, writeError: .writeFailed(errno: EIO)))
                    sequence += 1
                    continue
                }
                records.append(ProbeRecord(sequence: sequence, sessionID: sessionID, offset: offset, length: buffer.count, kind: .filler, generation: generation))
                sequence += 1
            }
            chunkBase += chunkBytes
        }
        let decoyFloor = max(above, reads.max() ?? 0)
        let excluded = Set(lastWrites.compactMap { offset, value in
            ([BlockKind.probe, .aliasA, .aliasB].contains(value.kind) && offset % Layout.unit == 0) ? offset : nil
        }).union(reads)
        let aboveFloorCandidates = ProbePlanner.decoyOffsets(above: decoyFloor, reportedSize: device.reportedSize, count: 4, round: evictionRound, seed: 0xD3C0_5EED, excluding: excluded)
        var decoys = aboveFloorCandidates
        if decoys.isEmpty {
            decoys = ProbePlanner.decoyOffsets(above: Layout.minCandidate - Layout.unit, reportedSize: device.reportedSize, count: 4, round: evictionRound, seed: 0xD3C0_5EED, excluding: excluded)
        }
        if decoys.isEmpty { lastRoundHadNoDecoys = true }
        for offset in decoys {
            try checkCancelled()
            let generation = nextGeneration(offset)
            buffer.withUnsafeMutableBytes { pattern.fill($0, offset: offset, kind: .decoy, generation: generation) }
            do {
                try buffer.withUnsafeBytes { try device.write(at: offset, from: $0) }
                bytesWritten += UInt64(buffer.count)
            } catch let error as IOError {
                if isFatal(error) { throw error }
                lastEvictionIncomplete = true
                records.append(ProbeRecord(sequence: sequence, sessionID: sessionID, offset: offset, length: buffer.count, kind: .decoy, generation: generation, writeError: error))
                sequence += 1
                continue
            } catch {
                lastEvictionIncomplete = true
                records.append(ProbeRecord(sequence: sequence, sessionID: sessionID, offset: offset, length: buffer.count, kind: .decoy, generation: generation, writeError: .writeFailed(errno: EIO)))
                sequence += 1
                continue
            }
            records.append(ProbeRecord(sequence: sequence, sessionID: sessionID, offset: offset, length: buffer.count, kind: .decoy, generation: generation))
            sequence += 1
        }
    }

    private func nextGeneration(_ offset: UInt64) -> UInt32 {
        let next = (lastWrites[offset]?.generation ?? UInt32.max) &+ 1
        lastWrites[offset] = (offset >= 9 * 1024 * 1024 ? .filler : .decoy, next)
        return next
    }

    private func syncBestEffort(records: inout [ProbeRecord]) throws(IOError) {
        try checkCancelled()
        do { try device.synchronize() }
        catch let error {
            if isFatal(error) { throw error }
            lastSyncError = error
            for index in records.indices.reversed() {
                if records[index].kind != .filler && records[index].kind != .decoy { break }
                if records[index].writeError == nil { records[index].syncError = error }
            }
            for index in records.indices where records[index].kind != .filler && records[index].kind != .decoy && records[index].writeError == nil {
                records[index].syncError = error
            }
        }
    }

    private func checkCancelled() throws(IOError) { if isCancelled() { throw .cancelled } }
    private func isFatal(_ error: IOError) -> Bool { error == .deviceGone || error == .identityChanged || error == .cancelled }
}
