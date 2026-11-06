# Offline APT bundle

`bundle.lock.json` binds the amd64 bundle image, snapshot, exact download
closures, and upstream source revision. The image exposes `/apt-bundle` with
the original signed Debian, Debian Security, and Docker indexes, the 67 Debian
package files in `debian-packages.txt`, and the five Docker packages in
`docker-packages.txt`. These closures describe downloads, not every package
inherited from the Debian base. `pinned-packages.txt` remains installation policy.

The Dockerfile copies bundle data through a scratch stage and mounts it read
only during an APT `RUN --network=none`. The reviewed, source-controlled
`prepare-apt.sh` creates isolated, file-only APT configuration. Debian uses the
pinned base's `/usr/share/keyrings/debian-archive-keyring.gpg`. Docker uses the
source-controlled `docker.asc`, mounted read only, with fingerprint
`9DC858229FC7DD38854AE2D88D81803C0EBFCD88`. Neither trust anchor comes from the
bundle. APT verifies repository signatures and package hashes. The image's
automatic-package state is seeded into isolated APT state and persisted back
after installation. The helper configuration, cache, lists, and logs are
removed in the same RUN.

The lock currently records a locally assembled OCI manifest digest.
The approved source helper is present, with its SHA-256 recorded in the lock.
Publication and anonymous public pulls remain pending. Do not use a mutable
tag, fetch a Docker signing key over the network, or execute a helper from the
bundle. The shared assembler and publication
commands are delivered separately; this repository adds no automatic publisher.

For regeneration, retain original signed indexes, fetch the exact closures
against the pinned base and package policy, verify signatures/hashes and the
reviewed Docker key fingerprint, and reassemble the OCI artifact. Review
manifest changes and update both the Dockerfile reference and lock to the
computed manifest digest. Before release, CI must verify anonymous public
pulls, locked closures and trust chain, offline APT installation, existing VPC
checks, and full application reproducibility with the established build
script/options. APK stages, Rust/Go builds and the separate litestream download
retain their current behavior. This creates a new application image candidate
requiring a new Brave-approved application digest. Do not deploy before public
bundle availability and a successful full reproducibility check.
