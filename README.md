# flashcheck

**flashcheck is a macOS project for checking whether removable flash storage can store the capacity it reports.** It is inspired by [F3](https://github.com/AltraMayor/f3) and is being built as a native Swift command-line tool.

> **Status: pre-alpha / not ready for real-device use.** The core algorithm is under development. The CLI and macOS disk integration are placeholders, hardware validation has not been completed, and commands shown in the design are not available yet. Do not use this repository to test a real disk.

## What it is intended to do

The planned commands are:

- `scan`: a quick sampled check, with deeper diagnosis when the samples show a problem.
- `probe`: a deeper capacity investigation using alias checks and a sampled boundary search.
- `full`: write and read back the entire reported device.

The engine is designed to distinguish address wrapping from discarded writes, rejected writes, and ordinary read or write failures. Its test suite uses simulated devices; those tests do not access physical disks.

These commands are **planned, not currently usable**. At this stage, the executable only prints its version. See [project status](#project-status) before building or installing anything.

## Safety

Raw-device testing writes to the selected device and can permanently destroy its data. The planned `probe` and `full` commands are destructive. Never run a future real-device command until the target, warning, confirmation flow, disk identity checks, and recovery plan have been reviewed and hardware validation is complete.

The project is intended to refuse internal disks, ambiguous targets, and unsafe device states. Those protections are not complete in this checkout. **Do not run this build against a physical disk.**

## Project status

Implemented work currently includes a Swift package, pattern tagging and verification, block-device abstractions, simulated storage devices, sampled screening, wrap detection, boundary search, and in-progress engine orchestration. The CLI target and macOS integration target still contain placeholders. Reporting, disk safety, end-to-end CLI behavior, release packaging, and real-device validation remain unfinished.

The project does not currently establish manufacturer authenticity. A sampled pass cannot prove every byte is usable; a failure may indicate counterfeit hardware, defective hardware, or an I/O problem. Physical-capacity estimates require sufficient evidence and may remain undetermined. The sampled modes have a 512 MiB scope floor; smaller media requires full verification once that mode is complete.

No real-device validation has been completed for this implementation. The planned hardware comparison with F3 has not been performed.

## Requirements

- macOS 13 or later (deployment target in `Package.swift`)
- Swift 6 toolchain and Xcode Command Line Tools
- Apple Silicon and Intel are intended targets; universal release builds have not yet been verified

## Build and test

Clone the repository and enter its directory:

```sh
git clone <repository-url>
cd flashcheck
```

Build and run the automated tests:

```sh
swift build
swift test
```

These commands build the project for development. `swift run flashcheck` currently prints a version string only; it does not scan, probe, or test a device.

## Homebrew installation

**There is no Homebrew formula or public release yet.** Installing this development checkout through Homebrew would create a misleading and unusable installation.

Once the CLI, safety checks, tests, and release process are ready, the planned community-tap install will look like:

```sh
brew install <github-user>/flashcheck/flashcheck
```

The project will publish a versioned source release and maintain a separate `homebrew-flashcheck` tap. The release guide explains the remaining packaging work: [`docs/releasing.md`](docs/releasing.md).

## How the capacity check works

Flash memory controllers may report a larger address space than the physical storage can hold. When writes beyond the real capacity wrap back to lower addresses, a read at the lower address can reveal the tag written to its alias. flashcheck's planned probe uses tagged writes, cache-eviction writes, and repeated alias trials to look for that evidence. For example, if a device claims 512 GB but wraps at 4 GB, writes separated by 4 GB may address the same physical storage.

When there is evidence of a usable-capacity boundary, the engine searches for it and reports the sampled bounds. It does not inspect every byte in `scan` or `probe`; `full` is intended to verify the entire reported address space and will take much longer.

Cache eviction has a limitation: a device with a cache larger than the configured eviction writes may return cached data and hide the underlying behavior. The 512 MiB scope floor means sampled modes cannot make reliable claims about real capacity below that point.

## Development

Read [CONTRIBUTING.md](CONTRIBUTING.md) before making changes. The design and implementation plan live under [`docs/`](docs/). They describe intended behavior; the implementation is not complete enough to treat every planned interface as available.

## License

MIT. See [LICENSE](LICENSE).
