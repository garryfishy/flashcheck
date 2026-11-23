import Darwin
import Foundation

public final class FileBlockDevice: BlockDevice {
    public let reportedSize: UInt64
    public let blockSize: Int
    private let fd: Int32
    private let io: PosixIO

    public init(path: String, size: UInt64, blockSize: Int = 512, create: Bool) throws(IOError) {
        self.reportedSize = size
        self.blockSize = blockSize
        self.io = PosixIO()

        let flags = create ? (O_RDWR | O_CREAT | O_TRUNC) : O_RDWR
        let descriptor = open(path, flags, mode_t(0o600))
        guard descriptor >= 0 else { throw .writeFailed(errno: errno) }
        if create && ftruncate(descriptor, off_t(size)) != 0 {
            let error = errno
            _ = close(descriptor)
            throw .writeFailed(errno: error)
        }

        self.fd = descriptor
    }

    deinit {
        _ = close(fd)
    }

    public func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(IOError) {
        precondition(offset % UInt64(blockSize) == 0, "offset must align to blockSize")
        precondition(buffer.count % blockSize == 0, "length must align to blockSize")
        try io.readFully(fd: fd, at: offset, into: buffer)
    }

    public func write(at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(IOError) {
        precondition(offset % UInt64(blockSize) == 0, "offset must align to blockSize")
        precondition(buffer.count % blockSize == 0, "length must align to blockSize")
        try io.writeFully(fd: fd, at: offset, from: buffer)
    }

    public func synchronize() throws(IOError) {
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw .writeFailed(errno: errno) }
    }
}
