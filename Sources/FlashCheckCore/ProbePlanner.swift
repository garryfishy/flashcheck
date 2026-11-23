public enum ProbePlanner {
    public static func stageAOffsets(reportedSize: UInt64, uniformCount: Int = 64, seed: UInt64) -> [UInt64] {
        guard reportedSize > Layout.minCandidate else { return [] }
        let unit = Layout.unit
        let last = (reportedSize - unit) / unit * unit
        var offsets = Set<UInt64>()
        var power = Layout.minCandidate
        while power < reportedSize {
            offsets.insert(power / unit * unit)
            if power >= unit { offsets.insert((power - unit) / unit * unit) }
            let (next, overflow) = power.multipliedReportingOverflow(by: 2)
            if overflow { break }
            power = next
        }
        let span = reportedSize - Layout.minCandidate
        if uniformCount > 0 {
            var random = SplitMix64(seed: seed)
            for index in 0..<uniformCount {
                let fraction = (UInt64(index) &* span) / UInt64(uniformCount)
                let cell = max(1, span / UInt64(uniformCount))
                let jitter = random.next() % cell
                let raw = min(reportedSize - 1, Layout.minCandidate + fraction + jitter)
                offsets.insert(raw / unit * unit)
            }
        }
        offsets.insert(last)
        return offsets.filter { $0 >= Layout.minCandidate && $0 <= last }.sorted()
    }

    public static func decoyOffsets(above: UInt64, reportedSize: UInt64, count: Int, round: Int, seed: UInt64) -> [UInt64] {
        decoyOffsets(above: above, reportedSize: reportedSize, count: count, round: round, seed: seed, excluding: [])
    }

    public static func decoyOffsets(above: UInt64, reportedSize: UInt64, count: Int, round: Int, seed: UInt64, excluding: Set<UInt64>) -> [UInt64] {
        guard count > 0, reportedSize > Layout.unit else { return [] }
        let unit = Layout.unit
        let floor = above / unit * unit
        guard floor <= reportedSize - unit else { return [] }
        let firstSlot = floor / unit + 1
        let lastSlot = (reportedSize - unit) / unit
        guard firstSlot <= lastSlot else { return [] }
        var rng = SplitMix64(seed: seed ^ UInt64(round) &* 0x9E37_79B9_7F4A_7C15)
        var selected = Set<UInt64>()
        let attempts = count.multipliedReportingOverflow(by: 256)
        let maxAttempts = attempts.overflow ? Int.max : attempts.partialValue
        var attempt = 0
        while selected.count < count && attempt < maxAttempts {
            attempt += 1
            let slotCount = lastSlot - firstSlot + 1
            let slot = lastSlot - rng.next() % slotCount
            let offset = slot * unit
            if !excluding.contains(offset) { selected.insert(offset) }
        }
        return selected.sorted()
    }
}
