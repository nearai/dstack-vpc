FROM rust:1.88-alpine@sha256:9dfaae478ecd298b6b5a039e1f2cc4fc040fc818a2de9aa78fa714dea036574d AS rust-builder
RUN apk add --no-cache musl-dev=1.2.5-r13
RUN rustup target add x86_64-unknown-linux-musl
WORKDIR /build
# Build from the workspace root so --locked uses the authoritative top-level
# Cargo.lock. service-mesh/Cargo.lock alone is stale and would force cargo to
# re-resolve git-branch deps (rocket@master, Dstack-TEE/dstack default-branch)
# against current HEADs — the exact drift we are trying to eliminate.
COPY Cargo.toml Cargo.lock /build/
COPY service-mesh/ /build/service-mesh/
# --locked: refuse to update Cargo.lock (pins git deps like rocket/Dstack-TEE).
# --release: debug binaries are not bit-reproducible (debuginfo + paths).
# --remap-path-prefix: strip absolute paths the compiler embeds (CWD + CARGO_HOME).
RUN RUSTFLAGS="--remap-path-prefix=$(pwd)=. --remap-path-prefix=${CARGO_HOME:-/usr/local/cargo}/registry=cargo-registry --remap-path-prefix=${CARGO_HOME:-/usr/local/cargo}/git=cargo-git" \
    cargo build --release --locked --target x86_64-unknown-linux-musl --bin dstack-mesh


FROM golang:1.25.12-alpine@sha256:56961d79ea8129efddcc0b8643fd8a5416b4e6228cfd477e3fd61deb2672c587 AS go-builder
WORKDIR /build
COPY vpc-api-server/ /build/
# -trimpath: strip absolute paths the compiler embeds.
# -buildvcs=false: don't embed git rev / dirty state into the binary.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -buildvcs=false -a -o vpc-api-server main.go


FROM alpine:3.22@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412 AS ko-builder
RUN apk add --no-cache wget=1.25.0-r1 jq=1.8.2-r0 bash=5.2.37-r0 squashfs-tools=4.6.1-r1
WORKDIR /build
COPY ./extract-modules.sh /build/
RUN ./extract-modules.sh


FROM debian:bookworm-slim@sha256:78d2f66e0fec9e5a39fb2c72ea5e052b548df75602b5215ed01a17171529f706 AS runtime

# Install all apt packages (Debian snapshot + Docker apt repo) in one layer,
# version-pinned via pinned-packages.txt for reproducibility.
#
# Step 1 sets up the Debian snapshot via HTTP. The base image (debian-slim)
# ships no ca-certificates, so HTTPS is impossible at this point. Apt verifies
# repo signatures locally with debian-archive-keyring, so HTTP is safe.
# Step 2 bootstraps ca-certificates + curl from the snapshot (now pinned).
# Step 3 adds Docker's apt repo (HTTPS works now that ca-certificates is in).
# Step 4 installs all remaining packages, including docker-ce* (versions in
# pinned-packages.txt enforced via Pin-Priority 1001).
#
# The previous version ran `curl https://get.docker.com | sh`, which pulled
# whatever Docker version was current at build time — a drift source and a
# supply-chain risk.
RUN --mount=type=bind,source=pinned-packages.txt,target=/tmp/pinned-packages.txt,ro \
    set -e; \
    # 1. Configure pinned Debian snapshot (HTTP for now, no ca-certificates yet).
    echo 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20250411T024939Z bookworm main' > /etc/apt/sources.list && \
    echo 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20250411T024939Z bookworm-security main' >> /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/10no-check-valid-until && \
    rm -rf /etc/apt/sources.list.d/* && \
    mkdir -p /etc/apt/preferences.d && \
    while IFS= read -r line; do \
        pkg=$(echo "$line" | cut -d= -f1); \
        ver=$(echo "$line" | cut -d= -f2-); \
        if [ -n "$pkg" ] && [ -n "$ver" ] && [ "$pkg" != "$ver" ]; then \
            printf "Package: %s\nPin: version %s\nPin-Priority: 1001\n\n" "$pkg" "$ver" >> /etc/apt/preferences.d/pinned-packages; \
        fi; \
    done < /tmp/pinned-packages.txt && \
    apt-get update && \
    # 2. Bootstrap ca-certificates and curl from the pinned snapshot.
    apt-get install -y --no-install-recommends ca-certificates curl && \
    # 3. Add Docker's apt repo (now that HTTPS works).
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    # 4. Install all remaining packages, including pinned docker-ce*.
    apt-get install -y --no-install-recommends \
        wget \
        jq \
        nginx \
        supervisor \
        gettext-base \
        socat \
        kmod \
        etcd-server \
        etcd-client \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin && \
    usermod -aG docker root && \
    rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache && \
    # 5. Reproducibility: etcd-server's postinst creates the `etcd` system user,
    #    and useradd stamps /etc/shadow field 3 (days-since-epoch of the last
    #    password change) with the build date — so this layer, and the whole
    #    image, drift by one every day even though every package version is
    #    pinned (a same-day double-build never sees it). Blank field 3 for every
    #    account; all are locked system accounts (* / !), so the field is unused.
    sed -i -E 's/^([^:]+:[^:]+):[0-9]+:/\1::/' /etc/shadow /etc/shadow-

# Install litestream for SQLite replication to S3.
# --no-hsts: don't create /root/.wget-hsts, which embeds the current wall-clock
# time and breaks layer reproducibility.
RUN wget -q --no-hsts -O /tmp/litestream.tar.gz \
        https://github.com/benbjohnson/litestream/releases/download/v0.3.13/litestream-v0.3.13-linux-amd64.tar.gz && \
    tar -xzf /tmp/litestream.tar.gz -C /usr/local/bin/ litestream && \
    rm /tmp/litestream.tar.gz

RUN mkdir -p /var/run/dstack \
    /etc/dstack \
    /etc/ssl/certs \
    /etc/ssl/private \
    /var/log/supervisor \
    /var/log/nginx \
    /configs \
    /lib/extra-modules \
    /var/lib/etcd \
    /etc/etcd

# Copy binaries (executable)
COPY --chmod=755 --from=rust-builder /build/target/x86_64-unknown-linux-musl/release/dstack-mesh /usr/local/bin/dstack-mesh
COPY --chmod=755 --from=go-builder /build/vpc-api-server /usr/local/bin/vpc-api-server
COPY --chmod=644 --from=ko-builder /build/netfilter-modules/*.ko /lib/extra-modules/

# Copy configs (read-only)
COPY --chmod=644 configs/nginx.conf /etc/nginx/nginx.conf
COPY --chmod=644 configs/nginx-client-proxy.conf /etc/nginx/conf.d/client-proxy.conf
COPY --chmod=644 configs/nginx-server-proxy.conf.template /etc/nginx/templates/server-proxy.conf.template
COPY --chmod=644 configs/nginx-lb.conf /configs/nginx-lb.conf
COPY --chmod=644 configs/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY --chmod=644 configs/headscale_config.yaml /etc/headscale/config.yaml
COPY --chmod=644 configs/litestream.yml /configs/litestream.yml

# Copy scripts (executable)
COPY --chmod=755 scripts/ /scripts/

COPY --chmod=644 .GIT_REV /etc/

# Remove all non-deterministic files
RUN rm -rf \
    /var/log/dpkg.log \
    /var/log/apt/*.log \
    /var/log/alternatives.log \
    /var/cache/ldconfig/aux-cache \
    /etc/machine-id \
    /var/lib/dbus/machine-id \
    /var/log/*.log \
    /tmp/* \
    /var/tmp/* && \
    # Ensure directories exist (dbus is no longer installed transitively now
    # that Docker comes from apt instead of get.docker.com, so /var/lib/dbus
    # may not exist) and create empty machine-id files for deterministic builds.
    mkdir -p /var/lib/dbus /var/log/apt /var/log/supervisor /var/log/nginx && \
    touch /etc/machine-id /var/lib/dbus/machine-id

EXPOSE 80 443 8091 8092 2379 2380

HEALTHCHECK CMD /scripts/healthcheck.sh

ENTRYPOINT ["/scripts/entrypoint.sh"]
CMD ["/scripts/auto-entry.sh"]
