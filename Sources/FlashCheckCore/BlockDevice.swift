public protocol BlockDevice: AnyObject {
    var reportedSize: UInt64 { get }
    var blockSize: Int { get }
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(IOError)
    func write(at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(IOError)
    func synchronize() throws(IOError)
}
