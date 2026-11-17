# PENDING PUBLICATION: locally assembled digest; anonymous pull is not verified.
FROM nearaidev/apt-bundle-dstack-vpc@sha256:69e94c621c7c320a2592d861adcdd049b793a9da523aa51a0f57c8bd46576059 AS apt-bundle
FROM scratch AS apt-bundle-files
COPY --from=apt-bundle /apt-bundle /apt-bundle

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

# Install all apt packages offline from signed Debian and Docker repositories.
# Package pins remain authoritative. The helper and Docker signing key are
# reviewed source inputs, independent of the bundle's package data.
RUN --network=none \
    --mount=type=bind,from=apt-bundle-files,source=/apt-bundle,target=/opt/apt-bundle,ro \
    --mount=type=bind,source=build/apt-bundle/prepare-apt.sh,target=/run/prepare-apt.sh,ro \
    --mount=type=bind,source=build/apt-bundle/docker.asc,target=/run/docker.asc,ro \
    --mount=type=bind,source=pinned-packages.txt,target=/tmp/pinned-packages.txt,ro \
    set -e; \
    bash /run/prepare-apt.sh --bundle /opt/apt-bundle \
        --snapshot 20250411T024939Z --config /tmp/apt-bundle.conf \
        --debian-keyring /usr/share/keyrings/debian-archive-keyring.gpg \
        --status /var/lib/dpkg/status --pins /tmp/pinned-packages.txt \
        --docker-keyring /run/docker.asc && \
    if [ -f /var/lib/apt/extended_states ]; then \
        cp /var/lib/apt/extended_states /tmp/apt-bundle.conf.d/state/extended_states; \
    fi && \
    export APT_CONFIG=/tmp/apt-bundle.conf && \
    apt-get update --error-on=any && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
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
    cp /tmp/apt-bundle.conf.d/state/extended_states /var/lib/apt/extended_states && \
    rm -rf /tmp/apt-bundle.conf /tmp/apt-bundle.conf.d \
        /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache && \
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
