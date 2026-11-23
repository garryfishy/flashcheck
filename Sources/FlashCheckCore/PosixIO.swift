import Darwin

public struct PosixIO: Sendable {
    public typealias Transfer = @Sendable (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int

    private let preadTransfer: Transfer
    private let pwriteTransfer: Transfer

    public init(pread: @escaping Transfer = PosixIO.systemPRead, pwrite: @escaping Transfer = PosixIO.systemPWrite) {
        self.preadTransfer = pread
        self.pwriteTransfer = pwrite
    }

    public static let systemPRead: Transfer = { fd, buffer, count, offset in
        Darwin.pread(fd, buffer, count, offset)
    }

    public static let systemPWrite: Transfer = { fd, buffer, count, offset in
        Darwin.pwrite(fd, buffer, count, offset)
    }

    public func readFully(fd: Int32, at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(IOError) {
        try transfer(fd: fd, offset: offset, count: buffer.count, baseAddress: buffer.baseAddress, isWrite: false)
    }

    public func writeFully(fd: Int32, at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(IOError) {
        try transfer(fd: fd, offset: offset, count: buffer.count, baseAddress: buffer.baseAddress, isWrite: true)
    }

    private func transfer(fd: Int32, offset: UInt64, count: Int, baseAddress: UnsafeRawPointer?, isWrite: Bool) throws(IOError) {
        guard count > 0 else { return }
        guard let baseAddress else {
            throw .short(expected: count, actual: 0)
        }
        var moved = 0
        var transientErrors = 0
        while moved < count {
            let currentOffset = offset + UInt64(moved)
            let pointer = UnsafeMutableRawPointer(mutating: baseAddress.advanced(by: moved))
            errno = 0
            let result = (isWrite ? pwriteTransfer : preadTransfer)(fd, pointer, count - moved, off_t(currentOffset))
            if result > 0 {
                moved += result
                transientErrors = 0
                continue
            }
            if result == 0 {
                throw .short(expected: count, actual: moved)
            }
            let error = errno
            if error == EINTR {
                continue
            }
            if error == EAGAIN {
                transientErrors += 1
                if transientErrors <= 3 { continue }
                throw .short(expected: count, actual: moved)
            }
            throw isWrite ? .writeFailed(errno: error) : .readFailed(errno: error)
        }
    }
}
