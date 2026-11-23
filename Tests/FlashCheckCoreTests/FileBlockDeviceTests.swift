import Foundation
import Testing
@testable import FlashCheckCore

@Test func fileDeviceRoundTrip() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let device = try FileBlockDevice(path: path, size: 8 * 1024 * 1024, create: true)
    let source = [UInt8](repeating: 0xA5, count: 65_536)
    try source.withUnsafeBytes { try device.write(at: 1 * 1024 * 1024, from: $0) }
    var result = [UInt8](repeating: 0, count: source.count)
    try result.withUnsafeMutableBytes { try device.read(at: 1 * 1024 * 1024, into: $0) }
    #expect(result == source)
}

@Test func misalignedOffsetTraps() async {
    await #expect(processExitsWith: .failure) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let device = try! FileBlockDevice(path: path, size: 4096, create: true)
        var bytes = [UInt8](repeating: 0, count: 512)
        try! bytes.withUnsafeMutableBytes { try device.read(at: 100, into: $0) }
    }
}
