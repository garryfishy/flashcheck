import Testing
@testable import FlashCheckCore

private func unitBuffer() -> [UInt8] { [UInt8](repeating: 0, count: PatternGenerator.unitSize) }

@Test func randomSessionKeysHaveDistinctNonzeroIDs() {
    let first = SessionKey.random()
    let second = SessionKey.random()
    #expect(first.id != second.id)
    #expect(first.id.contains { $0 != 0 })
    #expect(second.id.contains { $0 != 0 })
}

@Test func roundTripMatches() {
    let generator = PatternGenerator(session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)))
    var bytes = unitBuffer()
    bytes.withUnsafeMutableBytes { generator.fill($0, offset: 0, kind: .probe, generation: 0) }
    let result = bytes.withUnsafeBytes { generator.verify($0, expectedOffset: 0, kind: .probe, generation: 0) }
    #expect(result == .match)
}

@Test func distinctOffsetsDiffer() {
    let generator = PatternGenerator(session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)))
    var a = unitBuffer(), b = unitBuffer()
    a.withUnsafeMutableBytes { generator.fill($0, offset: 0, kind: .probe, generation: 0) }
    b.withUnsafeMutableBytes { generator.fill($0, offset: UInt64(PatternGenerator.unitSize), kind: .probe, generation: 0) }
    #expect((0...(a.count - 32)).allSatisfy { start in Array(a[start..<(start + 32)]) != Array(b[start..<(start + 32)]) })
    #expect(a != b)
}

@Test func movedBlockIsForeign() {
    let generator = PatternGenerator(session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)))
    var bytes = unitBuffer()
    bytes.withUnsafeMutableBytes { generator.fill($0, offset: 65_536, kind: .probe, generation: 0) }
    let result = bytes.withUnsafeBytes { generator.verify($0, expectedOffset: 0, kind: .probe, generation: 0) }
    #expect(result == .foreign(offset: 65_536, kind: .probe, generation: 0))
}

@Test func olderGenerationIsStale() {
    let generator = PatternGenerator(session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)))
    var bytes = unitBuffer()
    bytes.withUnsafeMutableBytes { generator.fill($0, offset: 0, kind: .probe, generation: 1) }
    let result = bytes.withUnsafeBytes { generator.verify($0, expectedOffset: 0, kind: .probe, generation: 2) }
    #expect(result == .stale(generation: 1))
}

@Test func otherSessionNeverMatches() {
    let a = PatternGenerator(session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)))
    let b = PatternGenerator(session: SessionKey(id: Array(1..<17), keyBytes: Array(32..<64)))
    var bytes = unitBuffer()
    bytes.withUnsafeMutableBytes { a.fill($0, offset: 0, kind: .probe, generation: 0) }
    let result = bytes.withUnsafeBytes { b.verify($0, expectedOffset: 0, kind: .probe, generation: 0) }
    #expect(result == .otherSession)
}

@Test func singleBitFlipIsGarbage() {
    let generator = PatternGenerator(session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)))
    var payload = unitBuffer()
    payload.withUnsafeMutableBytes { generator.fill($0, offset: 0, kind: .probe, generation: 0) }
    payload[100] ^= 1
    #expect(payload.withUnsafeBytes { generator.verify($0, expectedOffset: 0, kind: .probe, generation: 0) } == .garbage)
    var header = unitBuffer()
    header.withUnsafeMutableBytes { generator.fill($0, offset: 0, kind: .probe, generation: 0) }
    header[24] ^= 1
    #expect(header.withUnsafeBytes { generator.verify($0, expectedOffset: 0, kind: .probe, generation: 0) } == .garbage)
}

@Test func blankDetected() {
    let generator = PatternGenerator(session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)))
    let bytes = [UInt8](repeating: 0xFF, count: PatternGenerator.unitSize)
    #expect(bytes.withUnsafeBytes { generator.verify($0, expectedOffset: 0, kind: .probe, generation: 0) } == .blank(0xFF))
}

@Test func forgedHeaderIsGarbage() {
    let generator = PatternGenerator(session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)))
    var bytes = unitBuffer()
    bytes.withUnsafeMutableBytes { generator.fill($0, offset: 65_536, kind: .probe, generation: 0) }
    bytes[24] = 0
    bytes[25] = 0
    bytes[26] = 0
    bytes[27] = 0
    bytes[28] = 0
    bytes[29] = 0
    bytes[30] = 0
    bytes[31] = 0
    #expect(bytes.withUnsafeBytes { generator.verify($0, expectedOffset: 0, kind: .probe, generation: 0) } == .garbage)
}
