# Agent release artifacts

BlakTail is pre-release. The repository currently has no published release tag, so
`scripts/install-agent.sh` must not be advertised as a working quickstart until a
release containing all required assets exists.

Each agent release uses one tag and these fixed asset names:

- `blaktaild-aarch64-apple-darwin.pkg`
- `blaktaild-x86_64-apple-darwin.pkg`
- `blaktaild-aarch64-unknown-linux-gnu.deb`
- `blaktaild-x86_64-unknown-linux-gnu.deb`
- `blaktaild-aarch64-unknown-linux-gnu.rpm`
- `blaktaild-x86_64-unknown-linux-gnu.rpm`
- `SHA256SUMS`

Build on the matching native operating system. Linux binaries must be built on the
oldest glibc baseline supported by that release; do not relabel a binary built for a
different target.

```sh
cargo build --locked --release -p blaktaild
BLAKTAIL_VERSION=0.1.0 BLAKTAIL_TARGET=aarch64-apple-darwin \
  scripts/package-agent.sh pkg target/release/blaktaild dist

# On native Linux builders, produce both formats from the same tested binary.
BLAKTAIL_VERSION=0.1.0 scripts/package-agent.sh deb target/release/blaktaild dist
BLAKTAIL_VERSION=0.1.0 scripts/package-agent.sh rpm target/release/blaktaild dist
```

`pkgbuild`, `dpkg-deb`, or `rpmbuild` is required for its corresponding format.
The package installs the binary and service definition but deliberately does not
enrol the node or enable the service. Join secrets never enter package metadata,
argv, or an environment file.

Public macOS packages must be built with
`BLAKTAIL_INSTALLER_IDENTITY="Developer ID Installer: …"`, notarised, and stapled.
The installer rejects an unsigned package. Linux artifacts are verified against the
release's `SHA256SUMS`; this detects corruption but is not a substitute for protecting
the GitHub release account.

After collecting all native artifacts:

```sh
scripts/agent-checksums.sh dist
gh release create v0.1.0 dist/blaktaild-* dist/SHA256SUMS \
  --title "BlakTail agent v0.1.0" --notes-file RELEASE_NOTES.md
```

Before calling the release usable, install the pinned tag on clean Debian/Ubuntu,
RPM-family Linux, Apple silicon macOS, and Intel macOS hosts. Confirm the displayed
version, one-time enrollment, service startup, restart persistence, and the
[two-node drill](two-node-drill.md). Publishing files alone is not this proof.

## Install a published release

Download and inspect the installer from the same tag, then run it as root:

```sh
VERSION=0.1.0
curl -fsSLO "https://raw.githubusercontent.com/jusso-dev/BlakTail/v${VERSION}/scripts/install-agent.sh"
less install-agent.sh
sudo BLAKTAIL_VERSION="$VERSION" sh install-agent.sh
```

Omitting `BLAKTAIL_VERSION` selects the latest release. Pinning is recommended for
controlled rollout and rollback.
