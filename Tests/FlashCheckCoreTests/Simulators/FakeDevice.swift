import Darwin
import Foundation
@testable import FlashCheckCore

enum BeyondUsable { case discard(fill: UInt8?), reject, limbo }

final class FakeDevice: BlockDevice {
    let reportedSize: UInt64
    let blockSize = 512
    private let usable: UInt64
    private let modulus: UInt64?
    private let beyond: BeyondUsable
    private let store = SparseStore()
    private var limbo: [UInt8] = []
    private var random: SplitMix64
    private(set) var writeCount = 0

    init(reported: UInt64, usable: UInt64, modulus: UInt64? = nil, beyond: BeyondUsable = .discard(fill: 0)) {
        self.reportedSize = reported; self.usable = usable; self.modulus = modulus; self.beyond = beyond
        self.random = SplitMix64(seed: 0xF1A5_1C4E)
    }
    private func mapped(_ offset: UInt64) -> UInt64 { modulus.map { offset % $0 } ?? offset }
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(IOError) {
        let address = mapped(offset)
        if address >= usable {
            switch beyond {
            case .discard(let fill):
                let byte: UInt8
                if let fill { byte = fill } else { byte = UInt8(truncatingIfNeeded: random.next()) }
                for i in 0..<buffer.count { buffer[i] = byte }
            case .reject: throw .readFailed(errno: EIO)
            case .limbo:
                for i in 0..<buffer.count { buffer[i] = limbo.isEmpty ? 0 : limbo[i % limbo.count] }
            }
        } else {
            let bytes = store.read(address, buffer.count)
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
        }
    }
    func write(at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(IOError) {
        writeCount += 1
        let address = mapped(offset)
        if address >= usable {
            switch beyond {
            case .discard: return
            case .reject: throw .writeFailed(errno: EIO)
            case .limbo: limbo = Array(buffer)
            }
        } else { store.write(address, Array(buffer)) }
    }
    func synchronize() throws(IOError) {}
}
