public enum IOError: Error, Equatable, Codable, Sendable {
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case short(expected: Int, actual: Int)
    case deviceGone
    case identityChanged
    case cancelled
}
