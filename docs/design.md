# FlashCheck — Design

Date: 2026-11-22
Status: Approved (2026-11-22)

## 1. Intent

A native macOS command-line tool, `flashcheck`, that tells a Mac user
whether a USB drive or SD card actually stores what it claims to — in
minutes, not hours — and, when it doesn't, how much it really holds.

Why: `f3probe` does this on Linux, but f3probe/f3fix have never been
ported to macOS (Homebrew's `f3` ships only `f3write`/`f3read`). The Mac
options today are a full write/read pass (hours for 512 GB) or a Linux VM.
The motivating example is a card advertised as 512 GB that holds about
3.9 GB. The project is intended for open-source release under the MIT license.

The input spec, `requirements.md` (in this directory), is
the requirements source. This document is the design that
satisfies it; where they differ, this document wins and says why.

## 2. Goals, non-goals, anti-goals

Goals
- Detect capacity misrepresentation: wrap-around (aliasing), silently
  discarded writes, rejected writes.
- Estimate real usable capacity when the evidence supports it, and say
  "undetermined" when it doesn't.
- Fast default scan that writes megabytes, not the whole card.
- Never touch the wrong disk. Safety fails closed.
- Every verdict traceable to recorded observations (JSON report).
- Engine is independent of macOS APIs and of the CLI, so it is fully
  testable against simulated devices and reusable by a later SwiftUI app.

Non-goals (v1)
- GUI. (Later, on the same engine.)
- Repairing the card to its real size (f3fix equivalent). Follow-up.
- Non-destructive mode that backs up and restores probed blocks.
- Homebrew formula / notarized release. v1 builds from source.
- Speed benchmarking beyond reporting measured throughput.

Anti-goals — failure even if it "works"
- Erasing any disk the user didn't clearly choose, or any internal/system
  disk under any flag.
- Saying `GENUINE`/`REAL`, or implying a passed sampled scan proves the
  product is authentic.
- Printing a physical capacity that the observations don't support.
- A fake card passing because reads were served from the card's cache.

## 3. Constraints

- Swift 6.
- Swift Package Manager, no third-party dependencies.
- Deployment target macOS 13+, arm64 + x86_64.
- Frameworks: Foundation, DiskArbitration, IOKit (only where DA lacks
  data), POSIX for raw I/O, CryptoKit for patterns.
- Raw writes need root: destructive commands run under `sudo`.
- Tests: Swift Testing. Tests never touch physical disks.

## 4. Approaches considered

| Approach | Trade-off | Decision |
|---|---|---|
| A. Swift CLI on a separate core engine; GUI later on the same engine | Ships soonest; proves the algorithm on real fakes before Apple app plumbing (privileged helper, notarization) | **Chosen** |
| B. SwiftUI app from day one | Friendliest, but raw disk writes from an app need a privileged helper + Developer ID ($99/yr); debugging algorithm and plumbing at once | Later stage |
| C. Keep Python | Python isn't on a fresh Mac; no path to a GUI | Rejected |

Cache handling (decided in conversation):

| Option | Trade-off | Decision |
|---|---|---|
| Evict the card's cache by writing filler between write and read-back (f3probe's approach) | Automatic, no replug; costs some extra writes; relies on filler > cache | **Chosen** |
| Ask user to replug between phases (prototype's approach) | Bulletproof vs cache, but adaptive probing needs dozens of write→read rounds; disk ID can change on replug | Rejected |

## 5. Architecture

```
Package.swift
Sources/
  FlashCheckCore/        # pure engine — no DiskArbitration/IOKit imports
    BlockDevice.swift      protocol + IOError taxonomy
    FileBlockDevice.swift  file-backed device (tests, --image)
    Pattern.swift          tagged, keyed probe blocks
    Probe.swift            ProbeRecord, observations
    Engine.swift           stages A/B/C orchestration
    WrapDetector.swift     controlled aliasing experiments
    BoundarySearch.swift   usable-size search
    Classifier.swift       observations -> verdict
    Report.swift           Codable report, text rendering
  FlashCheckMac/         # macOS-only glue
    DiskCatalog.swift      Disk Arbitration enumeration + description
    DiskSafety.swift       target policy (pure function over DiskFacts)
    DiskIdentity.swift     fingerprint + re-validation
    RawDiskDevice.swift    BlockDevice over /dev/rdiskN
    DiskClaim.swift        unmount, DA claim, disappear callback
    Privileges.swift       drop root after open
  flashcheck/            # CLI
    main.swift, Commands/*, Warning.swift, Progress.swift
Tests/
  FlashCheckCoreTests/     simulators + engine tests
  FlashCheckMacTests/      DiskSafety policy tests over fake DiskFacts
prototype/sizecheck.py     reference only
```

Key seam: `DiskSafety` takes a plain `DiskFacts` struct (built from DA in
production, built by hand in tests), so every safety rule is unit-tested.

### 5.1 BlockDevice

```swift
public protocol BlockDevice: AnyObject {
    var reportedSize: UInt64 { get }   // bytes
    var blockSize: Int { get }         // logical sector size
    func read(at offset: UInt64, into buf: UnsafeMutableRawBufferPointer) throws(IOError)
    func write(at offset: UInt64, from buf: UnsafeRawBufferPointer) throws(IOError)
    func synchronize() throws(IOError) // flush to media
}
```

- `read`/`write` loop on short transfers and `EINTR`; a short transfer that
  cannot complete throws `IOError.short(expected:actual:)`. An incomplete
  write is never success.
- Offsets and lengths must be multiples of `blockSize`; violation is a
  programmer error (precondition).
- `IOError`: `.readFailed(errno)`, `.writeFailed(errno)`, `.short`,
  `.deviceGone`, `.identityChanged`, `.cancelled`.
- `RawDiskDevice` opens `/dev/rdiskN` `O_RDWR`, sets `F_NOCACHE`, gets size
  via `DKIOCGETBLOCKCOUNT`×`DKIOCGETBLOCKSIZE`, and `synchronize()` issues
  `DKIOCSYNCHRONIZE`. Sync is **best effort**: many SD/USB bridges ignore
  it, so it is never treated as evidence that data reached flash or left
  the cache — only eviction (§5.3) is. Before each batch it checks a
  "device still valid" flag set by the DA disappear callback.

Simulators (test target, all over an in-memory sparse store):
`GenuineDevice`, `WrapDevice(physical:, modulus:)`,
`DiscardDevice(physical:)` (reads past boundary return 0x00/0xFF/garbage —
configurable), `RejectDevice(physical:)` (I/O error past boundary),
`LimboDevice(physical:)` (keeps the last out-of-range write in a one-slot
buffer and serves it back for any out-of-range read),
`CachedDevice(wrapping:, cacheBytes:)` (LRU read/write cache in front of any
device — models the cache trap), `CorruptingDevice(rate:, seed:)`,
`FlakyDevice` (intermittent errors), `ShortIODevice`, `VanishingDevice`
(throws `.deviceGone` after N ops), `StaleDataDevice` (pre-filled with a
previous session's valid blocks).

### 5.2 Probe blocks (tagged patterns)

Probe unit = 64 KiB (multiple of any sector size; big enough to defeat
"returns the last sector repeated" tricks, small enough to keep scans cheap).
Each unit:

```
header (64 bytes):
  magic "FLSHCHK1"
  sessionID      16 bytes, random per run
  logicalOffset  UInt64   where this block was *meant* to be written
  kind           UInt8    probe | filler | sentinel | aliasA | aliasB
  generation     UInt32   rewrite counter for this offset
  headerMAC      16 bytes (truncated HMAC-SHA256 of the above, keyed by session key)
payload: HMAC-SHA256 counter-mode stream keyed by (session key, offset, generation)
```

Verification of a read buffer yields exactly one of:
- `.match` — header and payload equal what we wrote here, this generation.
- `.foreign(offset: Y, kind:, generation:)` — a *valid, MAC-checked* block of
  **this session** that was written to a different offset Y. This is direct
  aliasing evidence: "reading X returned what we wrote at Y".
- `.stale` — valid block of this session, right offset, older generation.
- `.otherSession` — magic present but MAC fails under our key (previous run).
- `.blank(byte)` — all 0x00 or all 0xFF.
- `.garbage` — anything else.

Because the session key is random per run, stale data from older runs can
never verify as `.match` or `.foreign`. Random corruption cannot forge a
valid MAC, so corruption is never mistaken for aliasing.

### 5.3 Cache eviction

After writing a batch and before reading it back: `synchronize()`, then
write `evictBytes` of `filler` blocks to a reserved filler region, plus
**decoy** units at a few high offsets not under test (see "limbo" below),
then `synchronize()` again, then read. Every read-back of data we've just
read also gets an eviction first — a second read straight after the first
proves nothing because it can come from the read cache.

"Limbo" fakes keep the most recent out-of-range write in a buffer and
serve it back. Low-address filler doesn't displace it; decoy writes to
other out-of-range offsets do. Hence decoys in every eviction, and no
round ever writes a single probe alone. Filler blocks are tagged too, so if a
filler write lands on a probe (wrap-around), the probe reads back as
`.foreign(kind: filler)` — still evidence, never silent.

`evictBytes` default 64 MiB in `scan`, 256 MiB in `probe`; overridable
with `--evict-size`. SD/USB-stick controllers have caches in the KB–low-MB
range; the default leaves a wide margin. Documented limitation: a device
with a larger RAM cache than `evictBytes` could pass; `full` mode is immune.

Reserved low layout (all offsets below the smallest wrap candidate):
`[0, 1 MiB)` never deliberately written (aliased writes may still land
there; the card is erased regardless — see warning), `[1 MiB, 9 MiB)` alias bases,
`[9 MiB, 9 MiB + evictBytes)` filler region (≤ 265 MiB, always below the
smallest candidate, 512 MiB). The engine refuses to run
`scan`/`probe` on devices reporting < 1 GiB (use `full`).

Scope floor: fakes whose **real** capacity is below ~512 MiB are out of
scope for `scan`/`probe`. On such a card the filler region itself aliases
onto the alias bases; the engine must detect that (filler tags read back at
alias bases) and report `INCONCLUSIVE` with "real capacity may be below
512 MiB — run `full`", never a pass. Real fakes on sale are ≥ 1–2 GB.

### 5.4 Algorithm

**Stage A — screen** (both `scan` and `probe`)
1. Choose ~128 probe offsets (deterministic from session seed): every power
   of two from 512 MiB up to reported size, each also minus one unit; ~64
   uniformly spread; the last unit of the device. All 64 KiB-aligned,
   outside the reserved region.
2. Pre-read each offset (before writing anything). Record what's there.
   (If a pre-read already returns `.foreign` it's a bug: none written yet.)
3. Write all probes in ascending order, evict, read all back. Evict again
   and read them all a second time to catch unstable reads.
4. Each `ProbeRecord` stores: offset, length, write result, sync result,
   read result(s), verification outcome(s), errno, sequence number,
   sessionID.

**Stage B — diagnose.** `scan` runs all of B only when Stage A shows any
non-`.match`, and then prints a capacity if one is established (so a fake
card gets its usable size from a quick scan). `probe` always runs B1 and
B3, and B2 whenever anything failed. The scan warning's byte estimate is
Stage A only, plus "more if problems are found".

B1. Wrap detection. Candidate moduli M: every power of two from 512 MiB up
to below reported size, ascending, plus any distance |X−Y| observed in a
`.foreign` result (covers non-power-of-two wraps). For each M, three trials
with different bases b in the alias-base region:
  write `aliasA` at b → evict → write `aliasB` at b+M → evict →
  read b and b+M.
  Trial confirms aliasing iff b reads `.foreign(offset: b+M, kind: aliasB)`.
  M is **confirmed** iff 3/3 trials confirm. 1–2/3 → "suspected", recorded,
  not used for capacity. Smallest confirmed M is the wrap modulus.
  Trials for different M may be batched in one write/evict/read round —
  tags tell us exactly which write landed where; any ambiguous result is
  re-run alone.

B2. Usable-size boundary search, over `[0, M)` if wrap confirmed, else
`[0, reported)`.
  - Each round is k-ary, not single-point: write fresh-generation probes
    at k (default 8) evenly spaced points inside (L, H), plus decoys above
    H, evict, read all k. New L/H = tightest good/bad pair. To 1 MiB
    resolution this takes ~5 rounds for a 4 GiB gap.
  - Lower bound L = highest offset known good, upper bound H = lowest
    known bad, starting from Stage A records.
  - Meaning of the result: "usable size" here is **sampled** — points
    below L read back correctly while writes above H were also happening.
    It is not proof that every byte below L holds data; the report says so
    and points to `full` for that. (A stricter f3probe-style
    fill-below-L check is left for the future repair command, which needs
    it.)
  - Then **monotonicity check**: re-test 8 random offsets in `[0, L)` (must
    be good) and 8 in `[H, top)` (must be bad), plus re-test L and H.
  - Pass → boundary established. Fail → boundary undetermined.

B3. Reproducibility. Any single isolated failure in Stage A is re-tested
twice with new generations. Fails 0/2 → `transient`; 1/2 →
`intermittent` (counts as unstable storage); 2/2 → `persistent`.

**Stage C — conclude.** See classification below.

**`full` mode:** sequential pass writing tagged units over the entire
device (no eviction needed: data written ≫ any cache), then sequential
read-back. Reports per-region outcome map, throughput, ETA during run.
Applies the same classifier, with "sampled" replaced by "full".

### 5.5 Classification

| Verdict | When |
|---|---|
| `CAPACITY MISREPRESENTATION DETECTED` | Wrap confirmed (B1), **or** boundary established (B2) below reported size with everything above it failing |
| `STORAGE INTEGRITY FAILURE` | Persistent failures that aren't a clean boundary or confirmed wrap (scattered, non-monotonic, unstable) |
| `SAMPLED TEST PASSED` | `scan`/`probe`: every probe `.match` on both reads, no wrap confirmed/suspected |
| `FULL VERIFICATION PASSED` | `full`: every unit `.match` |
| `INCONCLUSIVE` | Only transient failures, or suspected-but-unconfirmed wrap, or too few observations |
| `TEST ERROR` | Device vanished, identity changed, unmount failed, cancelled, I/O setup failed |

Capacity line:
- Boundary established → `Usable: ~3.96 GB (verified up to X, fails from Y; resolution 1 MiB)`.
- Wrap confirmed, boundary not → `Wraps every M; usable ≤ M; exact size undetermined`.
- Otherwise → `PHYSICAL CAPACITY UNDETERMINED` (+ verified lower bound if any).

Text output separates **Observations** (counts, outcomes, alias pairs with
trial results) from **Interpretation** (verdict, capacity, caveats). Always
ends with the two caveats: sampled ≠ every byte; no verdict proves the
product genuine.

Exit codes: 0 passed, 10 misrepresentation, 11 integrity failure,
12 inconclusive, 20 test error, 64 usage error, 77 refused for safety.

### 5.6 Reports

`Report` is `Codable`, fields stable: `toolVersion`, `algorithmVersion`,
`mode`, `sessionID`, `device{…}`, `startedAt`, `durations`, `bytesWritten`,
`bytesRead`, `probes[]`, `aliasTrials[]`, `boundary{…}`, `verdict`,
`capacity{…}`. Saved every run to
`~/Library/Logs/FlashCheck/<timestamp>-<model>.json` (owned by the real
user, not root). `--json` additionally prints it to stdout.

## 6. Disk safety (P0)

### 6.1 Target policy — `DiskSafety.evaluate(DiskFacts) -> Allowed | Refused(reason)`

Refuse unless **all** hold:
1. Whole disk (`DAMediaWhole`), not a partition, not APFS-synthesized,
   not a virtual/disk-image device.
2. Not the physical store of the boot volume or of any volume mounted at
   `/`, `/System/Volumes/*`, or the user's home. (Resolve `statfs("/")`
   → APFS container → physical store whole-disk via IOKit parent walk.)
3. Not hosting any APFS container that holds a system role volume.
4. Either `DADeviceInternal == false` (external bus), **or** internal with
   `DAMediaRemovable == true` (built-in SD reader). Internal +
   non-removable is always refused. Ejectable alone is not sufficient.
5. Writable (`DAMediaWritable`), size > 0, block size 512 or 4096.
5a. No volume on the disk (or in an APFS container on it) is a Time
   Machine/backup destination (APFS role Backup, or an HFS+
   `Backups.backupdb`), and none has a System/Data/Preboot/Recovery/VM role.
   (Author's decision: external USB SSDs/HDDs are allowed, since fake
   "portable SSDs" are common, but backup and system drives never are.)
6. All facts present; any missing key → refuse ("can't establish identity").

No flag overrides these. `--image <file>` is the only way to run the engine
non-interactively, and it never opens a `/dev` node.

### 6.2 Identity

Fingerprint captured when the user confirms: IORegistry entry ID, DA
device path, media size, block size, vendor, model, media name, BSD name,
BSD major/minor. Re-validated (all fields equal) immediately before
`open()`, and again **after** `open()` by matching the fd's `fstat`
`st_rdev` to the IOMedia's BSD major/minor and re-reading the entry ID
(BSD names are reused after a replug, so the name alone proves nothing).
Any difference or missing disk → close, `TEST ERROR`, nothing written. The DA disappear
callback flips the device-valid flag; any later I/O throws `.deviceGone`.
The tool never reconnects to a reappeared device.

### 6.3 Unmount and claim

`DADiskUnmount(whole, kDADiskUnmountOptionWhole)` (without that option the
partitions stay mounted and the raw `open` fails with `EBUSY`). If the card
holds an APFS container, the synthesized container disk's volumes are
unmounted too. Any failure → abort before opening. Then confirm from the
mount table that no volume on this disk or its containers is mounted.

`DADiskClaim` plus a mount-approval callback stop **auto-mount** and other
Disk Arbitration clients during the run. They do not stop another process
doing a raw `open()`, and the design doesn't count on them for that. The
mount table is re-checked between batches; a remount → stop, `TEST ERROR`.

### 6.4 Privileges

`list` and `info` run as the normal user. `scan`/`probe`/`full` require
root (clear message telling the user to prefix `sudo`). Order: evaluate
policy → show warning → confirm → re-validate identity → unmount/claim →
open raw device → **drop to `SUDO_UID`/`SUDO_GID`** → run engine → write
report as the user.

### 6.5 Cancellation

SIGINT sets a flag checked between I/O operations; the current transfer
completes, nothing new starts, partial report saved as `TEST ERROR
(cancelled)`, and the user is told the card is in an unknown state and
must be reformatted.

## 7. The warning

Every destructive command, before any confirmation, prints in plain
language exactly what will happen to the storage. Example for `scan`:

```
flashcheck scan disk4

  Device      Built In SDXC Reader (SD card)
  Identifier  /dev/disk4
  Claims      536.9 GB
  Volumes     "Untitled" (exFAT, 12.4 GB used) — will be unmounted

  WHAT WILL HAPPEN TO THIS CARD

  • Everything on it will be ERASED: all files, all partitions.
    This cannot be undone. Copy anything you need first.
  • flashcheck writes test data directly to the card, about 90 MB
    for this scan, spread across the whole card.
  • When it finishes, the card will be blank (no file system).
    macOS may say "The disk you inserted was not readable" —
    choose Ignore. To use the card again, reformat it:
      diskutil eraseDisk ExFAT CARD MBRFormat /dev/disk4
  • Expected time: a few minutes (depends on the card's speed).
  • Wear: negligible. (full mode writes the entire card once.)

  To continue, type the identifier exactly (disk4):
```

- Byte estimate comes from the planner for that mode (Stage A + expected
  eviction rounds; `probe` shows a range because Stage B is adaptive;
  `full` shows the full size and "hours on slow cards").
- Every volume is listed with its name, format and space used, so the
  user can see what they're about to lose.
- Anything other than the exact identifier aborts (exit 77). No `-y`.
- The same "will be blank, reformat with …" note is repeated in the final
  report.
- `list` and `info` say up front that they don't change the card.

## 8. CLI

```
flashcheck list                 # removable/external disks, with "testable?" + reason
flashcheck info disk4           # facts + safety verdict, read-only
sudo flashcheck scan disk4      # quick: Stage A (+B if anything fails)
sudo flashcheck probe disk4     # deep: A + full B, capacity estimate
sudo flashcheck full disk4      # every byte
flashcheck scan --image f.img   # file-backed, no root, no prompt
  --json  --evict-size 128M  --log probes.ndjson  --version  --help
```

Accepts `disk4` or `/dev/disk4` (normalized; `rdisk` accepted).
Progress on one line (`stage, n/N, bytes written, MB/s`), plain lines when
stdout isn't a TTY. Never auto-selects a disk.

## 9. Testing

Engine tests (Swift Testing, deterministic seeds), each asserting verdict,
capacity output, and that observations back the verdict:

| Simulated device | Expected |
|---|---|
| Genuine 64 GiB | `SAMPLED TEST PASSED`, no capacity claim |
| Genuine behind 32 MiB cache | passes (cache doesn't cause false alarm) |
| Wrap 4 GiB / claims 512 GiB | misrepresentation, wrap 4 GiB confirmed |
| Wrap 32 GiB / 512 | same, 32 GiB |
| Wrap 4 GiB **behind 8 MiB cache** | still detected (eviction works) |
| Wrap with cache > evictBytes | documented miss: test asserts the known limitation (not a pass of the product) |
| Discard 3.9 GiB (non-power-of-two) / 512 | misrepresentation, boundary within 1 MiB of 3.9 GiB |
| Reject (I/O error) past 32 GiB | misrepresentation, boundary ~32 GiB |
| Wrap 4 GiB + discard past 3.7 GiB | wrap 4 GiB and usable ~3.7 GiB |
| Limbo 3.9 GiB / 512 | misrepresentation, boundary within 1 MiB (not too high) |
| Wrap 256 MiB / 64 GiB (below scope floor) | `INCONCLUSIVE` with "may be below 512 MiB", never a pass |
| Random corruption 1e-4 | integrity failure, **no** wrap confirmed |
| Flaky reads | inconclusive or integrity failure, never misrepresentation |
| Stale previous-session data | never `.match`; genuine still passes |
| Short I/O | detected, retried, or `TEST ERROR`; never counted as success |
| Vanishes mid-run | `TEST ERROR`, no writes after vanish |

Safety tests: table of `DiskFacts` cases → expected result: internal SSD
(refuse), boot store (refuse), APFS synthesized (refuse), partition
(refuse), disk image (refuse), missing keys (refuse), SD in built-in
reader (allow), USB stick (allow), USB SSD with ordinary data (allow),
USB SSD holding a Time Machine volume (refuse), external disk with a
macOS system volume (refuse). Identity-change test.

Real-hardware validation (manual, Phase 5): run `list` and `info` on a
macOS development system (non-destructive). Then the known fake card: expected
`CAPACITY MISREPRESENTATION DETECTED`, discard-type, usable boundary
consistent with f3read's 7,604,023 good sectors (raw boundary ≈ 3.9–4.0 GB
once partition/FS offsets are added). Then a known-good card: expected pass.

## 10. Build order

1. Package skeleton, `BlockDevice`, `FileBlockDevice`, simulators.
2. Patterns + verifier (with forgery/stale tests).
3. Stage A, eviction, records.
4. Wrap detection; boundary search; classifier.
5. Report (text + JSON).
6. macOS: DiskCatalog, DiskSafety (+ tests), identity, claim/unmount,
   RawDiskDevice, privilege drop.
7. CLI commands, warning, progress, exit codes.
8. README (spec §14 list), then real-hardware validation.

## 11. Left to the builder

- Exact probe counts and spacing beyond the rules above.
- Batching strategy for B1 trials.
- Internal type names and file splits.
- Progress rendering details.
- How `full` chunks its I/O (bounded buffers, ≤ 8 MiB).

## 12. Design decisions

- MIT license.
- macOS 13+, universal binary.
- Cache eviction instead of replug.
- Open as root, then drop privileges.
- 64 KiB probe unit; 64/256 MiB default eviction.
- Wrap moduli tested as powers of two plus any distance seen in `.foreign`
  reads (f3probe likewise reports power-of-two modules); usable size is
  found by boundary search so it need not be a power of two.
- Reports auto-saved to `~/Library/Logs/FlashCheck/`.
- Usable size from `scan`/`probe` is a sampled estimate (k-ary boundary
  search with decoys), labelled as such; `full` is the every-byte check.
- `scan` runs diagnostics and prints a capacity when Stage A finds
  problems.
- Scope floor: real capacity ≥ ~512 MiB for `scan`/`probe`; smaller →
  `INCONCLUSIVE`, suggest `full`.
- Repair (f3fix-style) and non-destructive mode deferred.
- Distribution: build from source in v1; Homebrew later.
