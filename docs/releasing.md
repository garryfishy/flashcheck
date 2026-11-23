# Release and Homebrew distribution

This is a release checklist, not a claim that a release is available. The repository has no configured Git remote, tagged release, or Homebrew tap, and the current CLI is a placeholder. Do not publish a formula until the release gates below are met.

## Release gates

- Complete the CLI, report rendering, native device discovery, identity validation, and disk-safety policy.
- Run the full automated suite on supported macOS versions and architectures.
- Complete non-destructive disk discovery checks.
- Complete destructive hardware validation only with explicit approval for a named disposable card; document the result.
- Verify release archives, version output, checksums, and install instructions from a clean macOS environment.
- Pick the canonical GitHub repository and create a stable version tag.

## Recommended first distribution: a community tap

Homebrew accepts third-party formulae from taps. A tap is a separate Git repository; Homebrew's documentation recommends a `homebrew-` repository name for GitHub taps. See [How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap) and the [Formula Cookbook](https://docs.brew.sh/Formula-Cookbook).

After the upstream project is public and has a stable release:

1. Create a `homebrew-flashcheck` repository under the chosen GitHub account.
2. Add `Formula/flashcheck.rb` to that tap. Use a versioned source archive URL, a real SHA-256 checksum, and the correct license and macOS requirements.
3. Have the formula build the Swift package in release mode and install the `flashcheck` executable into Homebrew's `bin` directory.
4. Test the formula locally with `brew install --build-from-source <github-user>/flashcheck/flashcheck`, then `brew test` and `brew audit --new --formula`.
5. Publish the formula and document the resulting install command in the upstream README.

The intended user command is:

```sh
brew install <github-user>/flashcheck/flashcheck
```

Homebrew can install a formula directly from a tap-qualified name without a separate `brew tap` command. Users should inspect and trust third-party formulae deliberately because formula code runs with the user's privileges. See [Homebrew Tap Trust](https://docs.brew.sh/Tap-Trust).

## Future formula shape

Do not copy this sketch into a live tap until the repository URL, version, checksum, and actual build/install behavior have been verified:

```ruby
class Flashcheck < Formula
  desc "Check reported capacity of removable flash storage"
  homepage "https://github.com/<github-user>/flashcheck"
  url "https://github.com/<github-user>/flashcheck/archive/refs/tags/v<VERSION>.tar.gz"
  sha256 "<sha256-of-the-release-archive>"
  license "MIT"

  uses_from_macos "swift" => :build
  depends_on macos: :ventura

  def install
    system "swift", "build", *std_swift_args
    bin.install ".build/release/flashcheck"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/flashcheck --version")
  end
end
```

The actual formula must be tested against the chosen minimum supported Swift/macOS versions. Confirm that version reporting and command-line behavior exist before relying on the test block. Homebrew recommends `uses_from_macos "swift" => :build` and `std_swift_args` for Swift formulas; declare an Xcode requirement separately only if the project needs full Xcode rather than the Command Line Tools. See [Homebrew's Swift formula guidance](https://docs.brew.sh/Language-Specific-Formulae#swift).

## Release steps

1. Update the version and release notes.
2. Run `swift test` and release builds on Apple Silicon and Intel.
3. Create and push a signed or otherwise verified version tag through the chosen release process.
4. Generate checksums for source and binary artifacts; publish them with the release.
5. Update the Homebrew formula URL and checksum, then test it from a clean environment.
6. Update the README install instructions only after the formula is published and tested.
