import Darwin
import Foundation
@testable import FlashCheckCore

final class CorruptingDevice: BlockDevice {
    private let inner: BlockDevice; private let rate: Double; private var random: SplitMix64
    var reportedSize: UInt64 { inner.reportedSize }; var blockSize: Int { inner.blockSize }
    init(_ inner: BlockDevice, bitErrorRate: Double, seed: UInt64) { self.inner = inner; rate = bitErrorRate; random = SplitMix64(seed: seed) }
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(IOError) {
        try inner.read(at: offset, into: buffer)
        guard rate > 0 else { return }
        for i in 0..<buffer.count { for bit in 0..<8 where Double(random.next() >> 11) / 9_007_199_254_740_992.0 < rate { buffer[i] ^= UInt8(1 << bit) } }
    }
    func write(at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(IOError) { try inner.write(at: offset, from: buffer) }
    func synchronize() throws(IOError) { try inner.synchronize() }
}

final class FlakyDevice: BlockDevice {
    private let inner: BlockDevice; private let rate: Double; private var random: SplitMix64
    var reportedSize: UInt64 { inner.reportedSize }; var blockSize: Int { inner.blockSize }
    init(_ inner: BlockDevice, readFailureRate: Double, seed: UInt64) { self.inner = inner; rate = readFailureRate; random = SplitMix64(seed: seed) }
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(IOError) {
        if Double(random.next() >> 11) / 9_007_199_254_740_992.0 < rate { throw .readFailed(errno: EIO) }
        try inner.read(at: offset, into: buffer)
    }
    func write(at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(IOError) { try inner.write(at: offset, from: buffer) }
    func synchronize() throws(IOError) { try inner.synchronize() }
}

final class VanishingDevice: BlockDevice {
    private let inner: BlockDevice; private let afterOperations: Int
    private var operations = 0
    private(set) var operationsAfterVanish = 0
    var reportedSize: UInt64 { inner.reportedSize }; var blockSize: Int { inner.blockSize }
    init(_ inner: BlockDevice, afterOperations: Int) { self.inner = inner; self.afterOperations = afterOperations }
    private func check() throws(IOError) {
        if operations >= afterOperations { operationsAfterVanish += 1; throw .deviceGone }
        operations += 1
    }
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(IOError) { try check(); try inner.read(at: offset, into: buffer) }
    func write(at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(IOError) { try check(); try inner.write(at: offset, from: buffer) }
    func synchronize() throws(IOError) { try check(); try inner.synchronize() }
}

final class ShortIODevice: BlockDevice {
    private let inner: BlockDevice; private let failEvery: Int; private var operations = 0
    var reportedSize: UInt64 { inner.reportedSize }; var blockSize: Int { inner.blockSize }
    init(_ inner: BlockDevice, failEvery: Int) { self.inner = inner; self.failEvery = max(1, failEvery) }
    private func check(_ count: Int) throws(IOError) { operations += 1; if operations % failEvery == 0 { throw .short(expected: count, actual: max(0, count - 1)) } }
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(IOError) { try check(buffer.count); try inner.read(at: offset, into: buffer) }
    func write(at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(IOError) { try check(buffer.count); try inner.write(at: offset, from: buffer) }
    func synchronize() throws(IOError) { try check(0); try inner.synchronize() }
}
