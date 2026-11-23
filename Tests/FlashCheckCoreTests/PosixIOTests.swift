import Foundation
import Testing
@testable import FlashCheckCore

private final class TransferLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(Int, off_t)] = []

    func append(_ value: (Int, off_t)) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [(Int, off_t)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Test func retriesEINTRThenSucceeds() throws {
    let calls = TransferLog()
    let io = PosixIO(pread: { _, pointer, count, _ in
        let countBefore = calls.values().count
        calls.append((count, 0))
        if countBefore == 0 { errno = EINTR; return -1 }
        pointer.initializeMemory(as: UInt8.self, repeating: 1, count: count)
        return count
    })
    var bytes = [UInt8](repeating: 0, count: 16)
    try bytes.withUnsafeMutableBytes { try io.readFully(fd: 0, at: 0, into: $0) }
    #expect(calls.values().count == 2)
    #expect(bytes == [UInt8](repeating: 1, count: 16))
}

@Test func continuesAfterShortTransfer() throws {
    let calls = TransferLog()
    let io = PosixIO(pwrite: { _, _, count, offset in
        calls.append((count, offset))
        return min(count, 100)
    })
    let bytes = [UInt8](repeating: 0, count: 250)
    try bytes.withUnsafeBytes { try io.writeFully(fd: 0, at: 512, from: $0) }
    #expect(calls.values().map(\.0) == [250, 150, 50])
    #expect(calls.values().map(\.1) == [512, 612, 712])
}

@Test func zeroProgressIsShortError() throws {
    let calls = TransferLog()
    let io = PosixIO(pread: { _, _, count, _ in
        let call = calls.values().count
        calls.append((count, 0))
        return call == 0 ? 100 : 0
    })
    var bytes = [UInt8](repeating: 0, count: 65_536)
    let error = #expect(throws: IOError.self) {
        try bytes.withUnsafeMutableBytes { try io.readFully(fd: 0, at: 0, into: $0) }
    }
    #expect(calls.values().map(\.0) == [65_536, 65_436])
    #expect(error == .short(expected: 65_536, actual: 100))
}

@Test func errnoBecomesReadFailed() throws {
    let io = PosixIO(pread: { _, _, _, _ in errno = EIO; return -1 })
    var bytes = [UInt8](repeating: 0, count: 8)
    let error = #expect(throws: IOError.self) { try bytes.withUnsafeMutableBytes { try io.readFully(fd: 0, at: 0, into: $0) } }
    #expect(error == .readFailed(errno: EIO))
}
