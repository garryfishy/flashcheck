# FlashCheck Requirements

This document defines the project requirements. The architecture and implementation decisions are documented in [design.md](design.md).

---

Project: Native macOS Flash Storage Authenticity & Capacity Tester

## 1. Project Overview

Build a native macOS command-line application in Swift that detects counterfeit, misrepresented, defective, or unreliable flash storage devices.

The project is inspired by F3 (Fight Flash Fraud), particularly `f3probe`, but should be designed specifically for macOS using native system APIs.

We currently have a working Python prototype called `sizecheck.py`. Use it as a reference for understanding the original approach, but do not blindly translate its implementation.

The goal is to create a fast, accurate, safe, and eventually open-source alternative for macOS users.

Primary objectives

1. Detect flash storage devices whose advertised capacity exceeds their actual usable capacity.
2. Detect address aliasing, wrapping, silent write failures, and data corruption.
3. Estimate actual usable capacity when sufficient evidence exists.
4. Perform fast screening without writing the entire advertised capacity.
5. Protect users from accidentally destroying data on the wrong disk.
6. Produce transparent, reproducible, evidence-based results.
7. Run natively on macOS using Swift.
8. Remain lightweight, testable, and suitable for future SwiftUI integration.

Important: The tool must never claim that a device is genuine simply because a sampled test passes. Manufacturer authenticity and storage-capacity integrity are separate questions.

## 2. Background: Existing Python Prototype

The current `sizecheck.py` implementation:

* Uses `diskutil` to retrieve disk information.
* Checks whether the selected device is removable or external.
* Rejects partitions and attempts to reject internal disks.
* Unmounts the selected disk.
* Generates 512 deterministic 1 MiB test blocks.
* Distributes probe offsets across the reported disk capacity.
* Writes unique patterns to those offsets.
* Flushes writes using `fsync`.
* Requires the user to disconnect and reconnect the device.
* Reads back each probe and verifies its contents.
* Estimates physical capacity from the first failed probe.

Actual test case: a Samsung-branded microSD card advertised as 512GB was tested. The reported device capacity was approximately 536.9GB. Results:

```
/dev/disk4: Built In SDXC Reader, claims 536.9 GB
Unmount of all volumes on disk4 was successful

verify 512/512  bad=508

FAKE or FAULTY.
508/512 probes failed.

Real usable size is about 3.2-4.2 GB
(claims 536.9 GB).
```

This is strong evidence of severe storage unreliability or capacity misrepresentation. However, the conclusion that the device physically contains approximately 4GB is not sufficiently established.

Fundamental flaw: the Python implementation estimates capacity based on the first failed probe. This is incorrect for many counterfeit-controller behaviors. For example, a device with 32GB of actual storage may claim 512GB and wrap logical addresses modulo its real capacity. Writing across the advertised address space may overwrite previously written test patterns, including patterns at low offsets. Consequently, the first failed probe does not necessarily identify the physical capacity boundary. The new Swift implementation must solve this problem.

## 3. Technology & Architecture

Language and platform: Swift; macOS; Swift Package Manager; native command-line executable; Foundation; Disk Arbitration framework; IOKit where necessary; POSIX raw-device I/O where appropriate; XCTest or Swift Testing.

Avoid third-party dependencies unless they provide a substantial technical advantage.

Suggested architecture (a suggestion, not mandatory; prefer clear separation of responsibilities over unnecessary abstraction):

```
Sources/
  FlashCheck/
    main.swift
  FlashCheckCore/
    DiskDiscovery.swift  DiskIdentity.swift  DiskSafety.swift  DiskAccess.swift
    ProbePlanner.swift   PatternGenerator.swift  ProbeExecutor.swift
    ProbeVerifier.swift  AliasingDetector.swift  CapacityEstimator.swift
    DiagnosticEngine.swift  ReportGenerator.swift
Tests/
  FlashCheckCoreTests/
    MockBlockDevice.swift  FakeCapacitySimulator.swift  ProbePlannerTests.swift
    AliasingTests.swift  CapacityEstimatorTests.swift  DiskSafetyTests.swift
    IntegrationTests.swift
```

Design principle: the probing algorithm must not depend directly on macOS disk APIs. Create a block-device abstraction so that the same detection engine can operate on (1) real removable storage, (2) file-backed virtual devices, (3) simulated counterfeit devices, (4) simulated faulty devices. This separation is essential for safe automated testing.

## 4. P0 — Critical Disk Safety

This is the highest priority. The application performs potentially destructive raw-disk operations. An incorrect implementation could erase a user's internal SSD or other important storage.

### 4.1 Device discovery
Implement native disk enumeration. Display: BSD device identifier; device name; reported capacity; device protocol; removable status; internal/external classification; whole-disk status; mounted volumes; read-only status; relevant stable device identifiers when available.

Support SD cards inserted into built-in MacBook SDXC readers. Do not assume that a device is unsafe merely because the reader is internally connected. However, never infer that a device is safe solely because it is ejectable.

### 4.2 Disk identity validation
Before any destructive operation:
1. Resolve and validate the selected device.
2. Confirm that it is a whole disk.
3. Verify the storage medium is removable or otherwise explicitly permitted under a conservative safety policy.
4. Reject the startup disk.
5. Reject disks containing the active system or data volumes.
6. Reject internal fixed storage.
7. Reject unsupported or ambiguous devices.
8. Verify device identity immediately before opening it for writing.
9. Detect changes in device identity between operations.
10. Abort when identity cannot be established confidently.

Use native APIs when possible rather than relying on parsing human-readable `diskutil` output. Disk identifiers such as `/dev/disk4` may change after reconnection. Do not assume that a reconnected device will retain the same BSD identifier.

### 4.3 Destructive confirmation
Require explicit user confirmation. Example:

```
WARNING: DESTRUCTIVE OPERATION

Device: /dev/disk4
Name: Built In SDXC Reader
Capacity: 536.9 GB

This operation writes directly to the selected disk.
Existing filesystems and user data may be destroyed.

Type the exact device identifier to continue:
```

Do not accept a generic `y` confirmation. For automated testing, allow noninteractive execution only against simulated or file-backed devices by default. Do not provide a convenient flag that silently bypasses physical-device safety checks.

### 4.4 Disk unmounting
Unmount all volumes before raw writes. Abort if unmounting fails. Detect if the device is remounted unexpectedly. Avoid racing with macOS filesystem mounting. Handle device disconnection gracefully. Never continue writing after device identity changes.

### 4.5 Raw I/O correctness
Implement: correct offset alignment; device block-size awareness; full-write verification; full-read verification; retry handling for interrupted system calls; explicit handling of short reads and writes; flush and synchronization operations; clear error propagation; resource cleanup on failure; safe cancellation behavior. Never interpret an incomplete write as successful. Never continue after an unexpected device change.

## 5. P0 — Accurate Capacity Detection

Distinguish: (1) correctly reported storage capacity; (2) counterfeit capacity with address wrapping; (3) counterfeit capacity with silently discarded writes; (4) faulty storage with corruption; (5) inconclusive results.

### 5.1 Avoid first-failure estimation
Do not calculate physical capacity using only the first failed probe. Instead, analyze: successful offsets; failed offsets; error types; data mismatch patterns; potential alias relationships; repeated observations; candidate physical capacity boundaries. If the evidence does not support a defensible estimate, return `PHYSICAL CAPACITY UNDETERMINED`. Do not invent a capacity.

### 5.2 Address aliasing detection
Implement controlled experiments to determine whether different logical addresses map to the same physical storage. Example:
1. Write unique pattern A to logical offset X.
2. Read X and confirm pattern A.
3. Write unique pattern B to logical offset Y.
4. Read X again.
5. Read Y.
6. Determine whether writing Y modified the data at X.

Repeat with carefully selected offsets. Potential aliasing evidence: data at X changes immediately after writing Y; X contains the exact unique pattern written to Y; the same relationship reproduces across multiple independent trials. Use distinct patterns for each experiment. Do not classify unrelated random corruption as confirmed address aliasing.

### 5.3 Candidate physical capacity detection
Investigate common counterfeit capacities: 2GB, 4GB, 8GB, 16GB, 32GB, 64GB, 128GB, 256GB. Also support non-power-of-two capacities. Do not assume that physical capacity is always a power of two. Candidate testing should investigate whether addresses separated by a suspected capacity map to the same physical location. Example:

```
Candidate capacity: 32 GiB
Write pattern A at offset 0
Verify pattern A
Write pattern B at offset 32 GiB
Read offset 0 again
If offset 0 now contains pattern B:
    Potential address aliasing detected
```

Repeat at multiple base offsets and verify both directions where appropriate. Account for devices that reject out-of-range writes instead of wrapping them.

### 5.4 Adaptive probing
Stage A — Initial screening: a small number of distributed tests across the reported capacity. Goals: detect obvious corruption; detect obvious address aliasing; identify suspicious regions; minimize total bytes written.

Stage B — Diagnostic probing, when failures occur: analyze their distribution; test candidate capacity boundaries; investigate potential alias relationships; distinguish read/write errors from data mismatches; repeat suspicious tests to check reproducibility.

Stage C — Capacity estimation. Produce one of: a defensible capacity estimate; a bounded capacity interval with explicit assumptions; a lower bound on verified storage; an inconclusive capacity result. Do not equate the number of successful sampled blocks with total usable capacity. Do not assume that a successful probe establishes all storage between sampled offsets as usable.

## 6. P0 — Correct Probe Patterns

Use deterministic, high-quality test patterns. Each probe must contain distinguishable data. Patterns should depend on logical offset and test session. Patterns should resist accidental false matches. The verifier must reproduce the expected pattern. Different offsets must not share identical test data. A test must detect stale data from previous runs. Consider a cryptographic hash or deterministic pseudorandom generator. Do not rely on a constant repeated byte pattern. Include a session identifier to distinguish tests performed at different times. If write and verification phases are separated, persist the required session metadata safely outside the target device.

## 7. P1 — Reliability & Error Classification

Every probe should record: logical offset; requested write length; actual write length; write status; flush status; read status; actual read length; data verification result; error details; timestamp or sequence number; test-session identifier.

Distinguish: **Write failure** (device rejects or fails to complete a write); **Read failure** (cannot return requested data); **Data mismatch** (returns different data); **Suspected address aliasing** (a write to one offset appears to affect another); **Confirmed aliasing behavior** (reproducible, controlled experiment demonstrates interference); **Unstable storage** (inconsistent results across repeated tests); **Inconclusive** (insufficient evidence). Do not automatically classify every mismatch as counterfeit storage.

## 8. P1 — Testing Modes

**8.1 Quick Scan** — rapidly detect obvious fake-capacity behavior. Small number of writes; distributed sampling; adaptive diagnostics when suspicious behavior is detected; clear warning that the test is not exhaustive. Prefer seconds to a few minutes on healthy devices; do not promise a fixed runtime.

**8.2 Deep Probe** — investigate suspected counterfeit storage and estimate physical capacity. Additional controlled aliasing experiments; adaptive boundary investigation; repeated verification; more detailed diagnostics. Still avoid writing the entire advertised capacity unless explicitly requested.

**8.3 Full Verification** — write test data across the entire usable address space; read back and verify all; detect corruption missed by sparse sampling; report measured write and read throughput; clear progress and ETA. May take hours. Not to be described as manufacturer authentication.

## 9. P1 — Reporting

Results must distinguish direct observations from interpretations. Example:

```
FlashCheck — Storage Diagnostic Report

Device
----------------------------------
Name: Samsung SD Card
Reported capacity: 536.9 GB
Connection: Built-in SDXC Reader

Test
----------------------------------
Mode: Deep Probe
Probes attempted: 512
Probes passed: 4
Probes failed: 508

Detected issues
----------------------------------
Severe data verification failures

Address aliasing:
Not yet confirmed

Capacity
----------------------------------
Reported: 536.9 GB
Estimated physical capacity: Unknown

Assessment
----------------------------------
STORAGE INTEGRITY FAILURE

The device failed most sampled verification
checks. It cannot currently be trusted to
store data reliably.

The exact physical capacity has not been
established.

This result does not independently prove
manufacturer authenticity.
```

When aliasing is demonstrated, include offset pairs and reproduction results. When a capacity estimate is supported, explain method and uncertainty.

Result classifications: `SAMPLED TEST PASSED`, `FULL VERIFICATION PASSED`, `CAPACITY MISREPRESENTATION DETECTED`, `STORAGE INTEGRITY FAILURE`, `INCONCLUSIVE`, `TEST ERROR`. Do not use `GENUINE` or `REAL` as a classification.

Output formats: human-readable terminal output; JSON report; optional detailed probe log. Stable machine-readable fields. Include tool version, test mode, and algorithm version.

## 10. P1 — Automated Testing

Comprehensive simulated-storage framework; tests must run without accessing real disks.

Simulated behaviors: genuine device; 4GB claiming 512GB (modulo wrap, out-of-range discarded, out-of-range rejected); 32GB claiming 512GB (same); non-power-of-two capacity; random corruption (must not be read as confirmed aliasing); intermittent failures; partial I/O (short writes/reads, interrupted ops); device replacement between discovery and destructive access; disconnect during testing; stale data from previous sessions.

Required assertions:
1. Genuine devices are not incorrectly classified as counterfeit solely because of normal behavior.
2. Fake-capacity devices with detectable aliasing are identified.
3. Silent write-discard behavior is reported accurately.
4. Random corruption is not mislabeled as confirmed address aliasing.
5. Capacity estimates are withheld when evidence is insufficient.
6. Disk safety checks fail closed.
7. Short reads and writes are detected.
8. Reported results match actual test observations.
9. Cancellation and disconnection do not cause unsafe continuation.

Include deterministic tests for reproducibility.

## 11. P2 — CLI Experience

```
flashcheck list
flashcheck info /dev/disk4
flashcheck scan /dev/disk4
flashcheck probe /dev/disk4
flashcheck full /dev/disk4
flashcheck probe /dev/disk4 --json
flashcheck --help
flashcheck --version
```

Clearly identify the target device; explain whether the operation is destructive; show meaningful progress and completed probe count; show errors without hiding them; support clean cancellation; save reports outside the tested device; consistent exit codes; never automatically select a target disk. Use elevated privileges only for operations that require them; avoid running unrelated logic as root.

## 12. Performance Requirements

Correctness over performance. Minimize unnecessary disk writes; avoid huge buffers; reuse bounded buffers; avoid excessive memory; efficient raw I/O; avoid unnecessary pattern regeneration; measure actual throughput; minimize redundant probes; adapt test depth to observed failures. No unsafe parallel raw writes. Sequential controlled experiments may be necessary for reliable aliasing detection.

Benchmarks: initial screening time; deep probe time; bytes written; bytes read; memory usage; detection accuracy against simulated devices.

## 13. P2 — Future SwiftUI Application

Do not build the GUI in the first implementation, but keep the core engine independent of the CLI. Potential features: device selection, capacity visualization, probe progress, storage health summary, exportable reports, corruption map, historical results. Do not compromise the CLI architecture for speculative GUI requirements.

## 14. Documentation

README containing: (1) purpose; (2) supported macOS versions and architectures; (3) build instructions; (4) installation; (5) CLI usage; (6) destructive-operation warnings; (7) quick scan vs full verification; (8) address aliasing explained; (9) capacity-estimation limitations; (10) testing instructions; (11) example reports; (12) known limitations.

Clearly state that: quick scans cannot prove every byte is usable; passing a sampled test does not prove the product is genuine; failing may indicate counterfeit hardware, defective hardware, or an I/O problem; physical-capacity estimates require evidence and may remain undetermined; raw-device testing may permanently destroy data.

## 15. Implementation Strategy

Phase 1 — Review and design (read prototype; identify limitations; review architecture; design block-device abstraction; define classifications; explain algorithm; identify platform risks). Deliver a concise technical plan before implementing destructive disk operations.

Phase 2 — Simulator and algorithm (simulated block devices; deterministic patterns; probe planning; aliasing detection; capacity inference; automated tests). Prove the algorithm against simulated devices before accessing real hardware.

Phase 3 — Native macOS integration (discovery; identity validation; safety checks; raw I/O; safe unmounting; destructive confirmation; integrate engine).

Phase 4 — CLI and reporting (commands; progress; summaries; JSON; error handling; docs).

Phase 5 — Validation (simulator tests; non-destructive discovery on macOS; safety checks; destructive tests only on explicitly approved disposable media; compare with F3 where feasible; document discrepancies).

## 16. Acceptance Criteria

Builds and runs natively; enumerates removable storage correctly; refuses dangerous or ambiguous targets; never proceeds after failed unmounting or identity validation; detects controlled aliasing in simulated counterfeit devices; identifies silent write-discard; handles corruption without falsely claiming aliasing; does not infer capacity from the first failed probe; evidence-based classifications; fast screening and deeper diagnostics; deterministic tests; readable and machine-readable reports; documents sampled-verification limits; does not claim manufacturer authenticity.

## 17. Final Instructions

Reliability-focused systems programming project, not a Python-to-Swift translation. Priorities: (1) Safety; (2) Correctness — never claim exact physical capacity without sufficient evidence; (3) Detection quality — distinguish aliasing, discarded writes, ordinary corruption; (4) Speed — detect obvious counterfeits without writing hundreds of GB; (5) Transparency — every conclusion traceable to observations; (6) Testability — validate against simulated storage before physical devices. Avoid unnecessary complexity and premature GUI development.
