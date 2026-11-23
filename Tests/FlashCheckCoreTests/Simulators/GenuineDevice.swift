import Foundation
@testable import FlashCheckCore

final class GenuineDevice: BlockDevice {
    let reportedSize: UInt64
    let blockSize: Int
    private let store = SparseStore()

    init(size: UInt64, blockSize: Int = 512) { self.reportedSize = size; self.blockSize = blockSize }
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(IOError) {
        let data = store.read(offset, buffer.count)
        for (i, byte) in data.enumerated() { buffer[i] = byte }
    }
    func write(at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(IOError) {
        store.write(offset, Array(buffer))
    }
    func synchronize() throws(IOError) {}
}
