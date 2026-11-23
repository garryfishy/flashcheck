import Foundation

public struct EngineConfig: Sendable {
    public var mode: Mode; public var evictBytes: UInt64; public var seed: UInt64
    public var onRecord: (@Sendable (ProbeRecord) -> Void)?; public var onTrial: (@Sendable (AliasTrial) -> Void)?
    public init(mode: Mode, evictBytes: UInt64, seed: UInt64, onRecord: (@Sendable (ProbeRecord) -> Void)? = nil, onTrial: (@Sendable (AliasTrial) -> Void)? = nil) { self.mode = mode; self.evictBytes = evictBytes; self.seed = seed; self.onRecord = onRecord; self.onTrial = onTrial }
    public static func defaults(for mode: Mode) -> EngineConfig { EngineConfig(mode: mode, evictBytes: mode == .scan ? 64 * 1024 * 1024 : 256 * 1024 * 1024, seed: 0) }
}
public enum EngineEvent: Sendable { case stage(String), probe(done: Int, total: Int), bytes(written: UInt64, read: UInt64), throughput(bytesPerSecond: Double) }

public final class Engine {
    public static let toolVersion = "0.1.0", algorithmVersion = 1
    private let device: BlockDevice; private let summary: DeviceSummary; private let session: SessionKey; private let config: EngineConfig
    private let onEvent: (EngineEvent) -> Void; private let isCancelled: () -> Bool
    public init(device: BlockDevice, summary: DeviceSummary, session: SessionKey, config: EngineConfig, onEvent: @escaping (EngineEvent) -> Void, isCancelled: @escaping () -> Bool) { self.device = device; self.summary = summary; self.session = session; self.config = config; self.onEvent = onEvent; self.isCancelled = isCancelled }
    public func run() -> Report {
        let start = Date(), sessionID = session.id.map { String(format: "%02x", $0) }.joined()
        var a: StageAResult?, wrap: WrapResult?, boundary: BoundaryResult?, full: FullResult?, errors: [String] = [], written: UInt64 = 0, read: UInt64 = 0
        var verdict: Verdict, capacity: CapacityFinding
        do {
            if isCancelled() { throw IOError.cancelled }
            let pattern = PatternGenerator(session: session)
            if config.mode == .full {
                onEvent(.stage("full verification"))
                let result = try FullVerifier.run(device: device, pattern: pattern, isCancelled: isCancelled) { done, total in onEvent(.probe(done: Int(done), total: Int(total))) }
                full = result.0; written = result.1; read = result.2
            } else if device.reportedSize < Layout.minDeviceSize {
                errors.append("device too small for sampled modes; use full")
            } else {
                let runner = RoundRunner(device: device, pattern: pattern, layout: Layout(evictBytes: config.evictBytes), isCancelled: isCancelled)
                onEvent(.stage("Stage A")); a = try StageA.run(runner, reportedSize: device.reportedSize, seed: config.seed) { done, total in
                    self.onEvent(.probe(done: done, total: total))
                }
                for record in a!.records { config.onRecord?(record) }
                let failed = !a!.allMatched
                if config.mode == .probe || failed {
                    onEvent(.stage("wrap detection")); wrap = try WrapDetector.run(runner, layout: Layout(evictBytes: config.evictBytes), candidates: WrapDetector.candidates(reportedSize: device.reportedSize, observedDistances: a!.foreignDistances), seed: config.seed)
                    if wrap!.confirmedModulus == Layout.minCandidate,
                       wrap!.trials.contains(where: { if case .foreign(_, .filler, _)? = $0.readAtBase { return true }; if case .foreign(_, .filler, _)? = $0.readAtAlias { return true }; return false }) {
                        wrap!.belowScopeFloor = true
                    }
                    for trial in wrap!.trials { config.onTrial?(trial) }
                    if failed {
                        let top = wrap!.confirmedModulus ?? device.reportedSize
                        let bracketRecords = a!.records.filter { $0.offset < top }
                        let lo = bracketRecords.filter { $0.isGood || a!.retests[$0.offset] == .transient }.map(\.offset).max()
                            ?? Layout(evictBytes: config.evictBytes).aliasBases.upperBound
                        let hi = bracketRecords.filter { !$0.isGood && a!.retests[$0.offset] != .transient }.map(\.offset).min() ?? top
                        onEvent(.stage("boundary search")); boundary = try BoundarySearch.run(runner, lo: lo, hi: hi, top: top, seed: config.seed)
                    }
                }
                written = runner.bytesWritten; read = runner.bytesRead
            }
            if isCancelled() { throw IOError.cancelled }
            let pair = Classifier.classify(mode: config.mode, reported: device.reportedSize, stageA: a, wrap: wrap, boundary: boundary, full: full)
            verdict = pair.0; capacity = pair.1
            if wrap?.belowScopeFloor == true {
                verdict = .inconclusive
                capacity = CapacityFinding(kind: .undetermined, reported: device.reportedSize, note: "real capacity may be below 512 MiB — run full")
            }
        } catch let error as IOError {
            errors.append(error == .cancelled ? "cancelled" : String(describing: error))
            verdict = .testError; capacity = CapacityFinding(kind: .undetermined, reported: device.reportedSize, note: error == .cancelled ? "card is in an unknown state; reformat it" : "I/O failed.")
        } catch {
            errors.append(String(describing: error)); verdict = .testError
            capacity = CapacityFinding(kind: .undetermined, reported: device.reportedSize, note: "I/O failed.")
        }
        if errors.first == "device too small for sampled modes; use full" { verdict = .testError; capacity = CapacityFinding(kind: .undetermined, reported: device.reportedSize, note: "device too small for sampled modes; use full") }
        if isCancelled() && verdict != .testError {
            errors.append("cancelled"); verdict = .testError
            capacity = CapacityFinding(kind: .undetermined, reported: device.reportedSize, note: "card is in an unknown state; reformat it")
        }
        onEvent(.bytes(written: written, read: read))
        return Report(toolVersion: Self.toolVersion, algorithmVersion: Self.algorithmVersion, mode: config.mode, sessionID: sessionID, device: summary, startedAt: start, durationSeconds: Date().timeIntervalSince(start), bytesWritten: written, bytesRead: read, stageA: a, wrap: wrap, boundary: boundary, full: full, verdict: verdict, capacity: capacity, errors: errors)
    }

}
