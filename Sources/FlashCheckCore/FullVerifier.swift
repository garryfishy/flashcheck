import Foundation

public enum FullVerifier {
    @_optimize(speed)
    public static func run(device: BlockDevice, pattern: PatternGenerator, isCancelled: () -> Bool, onProgress: (UInt64, UInt64) -> Void) throws(IOError) -> (FullResult, UInt64, UInt64) {
        let unit = UInt64(PatternGenerator.unitSize), total = Int(device.reportedSize / unit)
        let chunkUnits = max(1, 8 * 1024 * 1024 / PatternGenerator.unitSize)
        var bytesWritten: UInt64 = 0, bytesRead: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkUnits * PatternGenerator.unitSize)
        let writeStart = Date()
        for chunkStart in stride(from: 0, to: total, by: chunkUnits) {
            if isCancelled() { throw .cancelled }
            let count = min(chunkUnits, total - chunkStart), byteCount = count * PatternGenerator.unitSize
            for index in 0..<count {
                let offset = UInt64(chunkStart + index) * unit
                buffer.withUnsafeMutableBytes { raw in pattern.fill(UnsafeMutableRawBufferPointer(start: raw.baseAddress!.advanced(by: index * PatternGenerator.unitSize), count: PatternGenerator.unitSize), offset: offset, kind: .full, generation: 0) }
            }
            do { try buffer.withUnsafeBytes { raw in try device.write(at: UInt64(chunkStart) * unit, from: UnsafeRawBufferPointer(start: raw.baseAddress, count: byteCount)) }; bytesWritten += UInt64(byteCount) }
            catch let error as IOError { throw error }
            catch { throw .writeFailed(errno: 5) }
            onProgress(UInt64(min(chunkStart + count, total)), UInt64(total))
        }
        try device.synchronize()
        let writeElapsed = max(Date().timeIntervalSince(writeStart), 0.000001)
        let readStart = Date()
        var bad: [UInt64] = [], matched = 0
        for chunkStart in stride(from: 0, to: total, by: chunkUnits) {
            if isCancelled() { throw .cancelled }
            let count = min(chunkUnits, total - chunkStart), byteCount = count * PatternGenerator.unitSize
            let offset = UInt64(chunkStart) * unit
            do { try buffer.withUnsafeMutableBytes { raw in try device.read(at: offset, into: UnsafeMutableRawBufferPointer(start: raw.baseAddress, count: byteCount)) } }
            catch let error as IOError {
                if error == .deviceGone || error == .identityChanged || error == .cancelled { throw error }
                bad.append(offset); continue
            } catch { bad.append(offset); continue }
            bytesRead += UInt64(byteCount)
            for index in 0..<count {
                let unitOffset = offset + UInt64(index) * unit
                let valid = buffer.withUnsafeBytes { raw in pattern.verify(UnsafeRawBufferPointer(start: raw.baseAddress!.advanced(by: index * PatternGenerator.unitSize), count: PatternGenerator.unitSize), expectedOffset: unitOffset, kind: .full, generation: 0) == .match }
                if valid { matched += 1 } else { bad.append(unitOffset) }
            }
        }
        let readElapsed = max(Date().timeIntervalSince(readStart), 0.000001)
        var ranges: [Range<UInt64>] = []
        for offset in bad {
            if let last = ranges.last, last.upperBound == offset { ranges[ranges.count - 1] = last.lowerBound..<(offset + unit) }
            else { ranges.append(offset..<(offset + unit)) }
        }
        return (FullResult(unitsTotal: total, unitsMatched: matched, firstBad: bad.first, badRanges: ranges, writeMBps: Double(bytesWritten) / writeElapsed / 1_000_000, readMBps: Double(bytesRead) / readElapsed / 1_000_000), bytesWritten, bytesRead)
    }
}
