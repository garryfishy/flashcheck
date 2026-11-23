final class SparseStore {
    private let pageSize = 65_536
    private var pages: [UInt64: [UInt8]] = [:]

    func read(_ off: UInt64, _ n: Int) -> [UInt8] {
        guard n > 0 else { return [] }
        var result = [UInt8](repeating: 0, count: n)
        var cursor = 0
        while cursor < n {
            let address = off + UInt64(cursor), pageIndex = address / UInt64(pageSize)
            let within = Int(address % UInt64(pageSize)), count = min(pageSize - within, n - cursor)
            if let page = pages[pageIndex] {
                result.withUnsafeMutableBytes { destination in
                    page.withUnsafeBytes { source in
                        destination.baseAddress!.advanced(by: cursor).copyMemory(from: source.baseAddress!.advanced(by: within), byteCount: count)
                    }
                }
            }
            cursor += count
        }
        return result
    }

    func write(_ off: UInt64, _ values: [UInt8]) {
        var cursor = 0
        while cursor < values.count {
            let address = off + UInt64(cursor), pageIndex = address / UInt64(pageSize)
            let within = Int(address % UInt64(pageSize)), count = min(pageSize - within, values.count - cursor)
            var page = pages[pageIndex] ?? [UInt8](repeating: 0, count: pageSize)
            page.withUnsafeMutableBytes { destination in
                values.withUnsafeBytes { source in
                    destination.baseAddress!.advanced(by: within).copyMemory(from: source.baseAddress!.advanced(by: cursor), byteCount: count)
                }
            }
            pages[pageIndex] = page
            cursor += count
        }
    }
}
