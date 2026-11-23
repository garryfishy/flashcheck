# Contributing

Thanks for considering a contribution. flashcheck handles storage-device writes, so correctness and safety take priority over convenience or speed.

## Current state

This is pre-alpha software. The CLI and native macOS disk integration are placeholders, and real-device testing is not yet supported. Please do not add instructions or examples that imply physical-device testing is safe or available.

## Before making changes

1. Read the approved design in `docs/design.md`.
2. Check the implementation plan in `docs/implementation-plan.md` and the design notes in `docs/design.md`.
3. Keep tests on simulated or file-backed devices. Never use a physical disk in automated tests.
4. Keep changes focused and document any change to the safety model or evidence used for a capacity finding.

## Build and test

Use Swift 6 on macOS 13 or later:

```sh
swift build
swift test
```

Some restricted development environments may require `--disable-sandbox` for SwiftPM. That is an environment workaround and is not needed for normal project use.

## Safety expectations

- Never automatically choose a target disk.
- Fail closed when device identity or safety information is missing or changes.
- Do not run destructive tests on real hardware without explicit approval naming the disposable device.
- Do not report a physical capacity unless the observations support it.
- A sampled pass must not be described as proof that a product is genuine.
- Preserve cancellation behavior and make I/O errors visible.

## Pull requests

Please include a concise problem statement, implementation summary, tests run, and any safety or compatibility impact. For algorithm changes, include the simulated device cases that demonstrate the expected behavior.
