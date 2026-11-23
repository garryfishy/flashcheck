import CryptoKit

public enum BlockKind: UInt8, Codable, Sendable {
    case probe = 1
    case filler
    case aliasA
    case aliasB
    case decoy
    case full
}

public enum Verification: Equatable, Codable, Sendable {
    case match
    case foreign(offset: UInt64, kind: BlockKind, generation: UInt32)
    case stale(generation: UInt32)
    case otherSession
    case blank(UInt8)
    case garbage
}

public struct PatternGenerator: Sendable {
    public static let unitSize = 65_536
    private let session: SessionKey
    public var sessionID: String { session.id.map { String(format: "%02x", $0) }.joined() }

    public init(session: SessionKey) { self.session = session }

    @_optimize(speed)
    public func fill(_ buf: UnsafeMutableRawBufferPointer, offset: UInt64, kind: BlockKind, generation: UInt32) {
        precondition(buf.count == Self.unitSize)
        var header = [UInt8](repeating: 0, count: 48)
        header.replaceSubrange(0..<8, with: Array("FLSHCHK1".utf8))
        header.replaceSubrange(8..<24, with: session.id)
        writeLE(offset, to: &header, at: 24)
        header[32] = kind.rawValue
        writeLE(generation, to: &header, at: 33)
        let digest = hmac(header)
        header.append(contentsOf: digest.prefix(16))
        for i in 0..<64 { buf[i] = header[i] }
        var rng = Xoshiro256StarStar(seed: digest)
        for i in stride(from: 64, to: Self.unitSize, by: 8) {
            let word = rng.next()
            buf.storeBytes(of: word.littleEndian, toByteOffset: i, as: UInt64.self)
        }
    }

    @_optimize(speed)
    public func verify(_ buf: UnsafeRawBufferPointer, expectedOffset: UInt64, kind: BlockKind, generation: UInt32) -> Verification {
        guard buf.count == Self.unitSize else { return .garbage }
        let first = buf[0]
        if (first == 0 || first == 0xFF) && buf.allSatisfy({ $0 == first }) { return .blank(first) }
        guard Array(buf[0..<8]) == Array("FLSHCHK1".utf8) else { return .garbage }
        let id = Array(buf[8..<24])
        guard id == session.id else { return .otherSession }
        let supplied = Array(buf[48..<64])
        let expectedMAC = hmac(Array(buf[0..<48]))
        guard supplied == Array(expectedMAC.prefix(16)) else { return .garbage }
        guard (37..<48).allSatisfy({ buf[$0] == 0 }), let actualKind = BlockKind(rawValue: buf[32]) else { return .garbage }
        let actualOffset = readLE(UInt64.self, from: buf, at: 24)
        let actualGeneration = readLE(UInt32.self, from: buf, at: 33)
        var rng = Xoshiro256StarStar(seed: expectedMAC)
        for i in stride(from: 64, to: Self.unitSize, by: 8) {
            let expected = rng.next().littleEndian
            if buf.loadUnaligned(fromByteOffset: i, as: UInt64.self) != expected { return .garbage }
        }
        if actualOffset != expectedOffset { return .foreign(offset: actualOffset, kind: actualKind, generation: actualGeneration) }
        if actualKind != kind || actualGeneration != generation { return .stale(generation: actualGeneration) }
        return .match
    }

    private func hmac(_ bytes: [UInt8]) -> [UInt8] {
        let key = SymmetricKey(data: session.keyBytes)
        return Array(HMAC<SHA256>.authenticationCode(for: bytes, using: key))
    }

    private func writeLE<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8], at start: Int) {
        for i in 0..<MemoryLayout<T>.size { bytes[start + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }

    private func readLE<T: FixedWidthInteger>(_ type: T.Type, from bytes: UnsafeRawBufferPointer, at start: Int) -> T {
        var result: T = 0
        for i in 0..<MemoryLayout<T>.size { result |= T(bytes[start + i]) << (i * 8) }
        return result
    }
}

private struct Xoshiro256StarStar {
    var state: (UInt64, UInt64, UInt64, UInt64)
    var word: UInt64 = 0

    init(seed: [UInt8]) {
        func word(_ start: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(seed[start + i]) << (8 * i) }
            return value
        }
        state = (word(0), word(8), word(16), word(24))
    }

    @_optimize(speed)
    @inline(__always)
    mutating func next() -> UInt64 {
        let result = state.1 &* 5
        let output = (result << 7 | result >> 57) &* 9
        let t = state.1 << 17
        state.2 ^= state.0; state.3 ^= state.1; state.1 ^= state.2; state.0 ^= state.3
        state.2 ^= t
        state.3 = state.3 << 45 | state.3 >> 19
        return output
    }
}
