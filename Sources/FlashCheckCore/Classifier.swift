import Foundation

public enum Classifier {
    public static func classify(mode: Mode, stageA: StageAResult?, wrap: WrapResult?, boundary: BoundaryResult?, full: FullResult?) -> (Verdict, CapacityFinding) {
        let reported = stageA?.records.map { $0.offset + UInt64($0.length) }.max() ?? 0
        return classify(mode: mode, reported: reported, stageA: stageA, wrap: wrap, boundary: boundary, full: full)
    }
    static func classify(mode: Mode, reported: UInt64, stageA: StageAResult?, wrap: WrapResult?, boundary: BoundaryResult?, full: FullResult?) -> (Verdict, CapacityFinding) {
        let note = "Capacity was sampled, not measured; no verdict proves the product genuine."
        if mode == .full, let full {
            if full.unitsMatched == full.unitsTotal { return (.fullPassed, CapacityFinding(kind: .established, reported: reported, usableLow: reported, usableHigh: reported, note: "Full device verified.")) }
            return (.misrepresentation, CapacityFinding(kind: .established, reported: reported, usableLow: full.firstBad, usableHigh: full.firstBad, note: "Full verification found unwritable or unreadable units."))
        }
        if wrap?.belowScopeFloor == true { return (.inconclusive, CapacityFinding(kind: .undetermined, reported: reported, note: "real capacity may be below 512 MiB — run full")) }
        if let boundary, boundary.established {
            return (.misrepresentation, CapacityFinding(kind: .established, reported: reported, usableLow: boundary.lastGoodEnd, usableHigh: boundary.firstBad, wrapModulus: wrap?.confirmedModulus, note: "Sampled usable capacity boundary established."))
        }
        if let modulus = wrap?.confirmedModulus {
            let extra = modulus == 512 * 1024 * 1024 ? "; true wrap period may be smaller" : ""
            return (.misrepresentation, CapacityFinding(kind: .wrapOnly, reported: reported, wrapModulus: modulus, note: "Confirmed wrap period\(extra)."))
        }
        if !(wrap?.suspected.isEmpty ?? true) { return (.inconclusive, CapacityFinding(kind: .undetermined, reported: reported, note: "Wrap suspected but not confirmed.")) }
        if let stageA {
            let nonTransient = stageA.records.contains { !$0.isGood && stageA.retests[$0.offset] != .transient }
            if nonTransient { return (.integrityFailure, CapacityFinding(kind: .undetermined, reported: reported, note: "Unstable or scattered storage failures.")) }
            if stageA.records.contains(where: { !$0.isGood }) { return (.inconclusive, CapacityFinding(kind: .undetermined, reported: reported, note: "Only transient failures observed.")) }
        }
        return (mode == .full ? .inconclusive : .sampledPassed, CapacityFinding(kind: .undetermined, reported: reported, note: note))
    }
}
