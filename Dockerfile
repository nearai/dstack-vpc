FROM rust:1.86-alpine@sha256:661d708cc863ce32007cf46807a72062a80d2944a6fae9e0d83742d2e04d5375 AS rust-builder
RUN apk add --no-cache musl-dev
RUN rustup target add x86_64-unknown-linux-musl
WORKDIR /build
COPY service-mesh/ /build/service-mesh/
WORKDIR /build/service-mesh
RUN cargo build --target x86_64-unknown-linux-musl


FROM golang:1.23-alpine@sha256:383395b794dffa5b53012a212365d40c8e37109a626ca30d6151c8348d380b5f AS go-builder
WORKDIR /build
COPY vpc-api-server/ /build/
RUN go mod init vpc-api-server || true
RUN go get github.com/gin-gonic/gin
RUN CGO_ENABLED=0 GOOS=linux go build -a -o vpc-api-server main.go


FROM alpine:3.22@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412 AS ko-builder
RUN apk add --no-cache wget jq bash squashfs-tools
WORKDIR /build
COPY ./extract-modules.sh /build/
RUN ./extract-modules.sh


FROM debian:bookworm-slim@sha256:78d2f66e0fec9e5a39fb2c72ea5e052b548df75602b5215ed01a17171529f706 AS runtime

# Bootstrap by installing ca-certificates which will be overridden by the pinned packages.
# Otherwise the source list cannot be fetched from the debian snapshot.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache

# Install pinned apt dependencies
RUN --mount=type=bind,source=pinned-packages.txt,target=/tmp/pinned-packages.txt,ro \
    set -e; \
    # Create a sources.list file pointing to a specific snapshot
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20250411T024939Z bookworm main' > /etc/apt/sources.list && \
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20250411T024939Z bookworm-security main' >> /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/10no-check-valid-until && \
    # Create preferences file to pin all packages
    rm -rf /etc/apt/sources.list.d/* && \
    mkdir -p /etc/apt/preferences.d && \
    cat /tmp/pinned-packages.txt | while read line; do \
        pkg=$(echo $line | cut -d= -f1); \
        ver=$(echo $line | cut -d= -f2); \
        if [ ! -z "$pkg" ] && [ ! -z "$ver" ]; then \
            printf "Package: %s\nPin: version %s\nPin-Priority: 1001\n\n" "$pkg" "$ver" >> /etc/apt/preferences.d/pinned-packages; \
        fi; \
    done && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        curl \
        jq \
        nginx \
        supervisor \
        gettext-base \
        socat \
        kmod \
        etcd-server \
        etcd-client \
        && rm -rf /var/log/* /var/cache/ldconfig/aux-cache

RUN curl -fsSL https://get.docker.com | sh \
    && usermod -aG docker root \
    && rm -rf /var/lib/apt/lists/* 

RUN mkdir -p /var/run/dstack \
    /etc/dstack \
    /etc/ssl/certs \
    /etc/ssl/private \
    /var/log/supervisor \
    /var/log/nginx \
    /scripts \
    /lib/extra-modules \
    /var/lib/etcd \
    /etc/etcd

COPY --from=rust-builder /build/service-mesh/target/x86_64-unknown-linux-musl/debug/dstack-mesh /usr/local/bin/dstack-mesh
RUN chmod +x /usr/local/bin/dstack-mesh

COPY --from=go-builder /build/vpc-api-server /usr/local/bin/vpc-api-server
RUN chmod +x /usr/local/bin/vpc-api-server

COPY --from=ko-builder /build/netfilter-modules/*.ko /lib/extra-modules/

COPY configs/nginx.conf /etc/nginx/nginx.conf
COPY configs/nginx-client-proxy.conf /etc/nginx/conf.d/client-proxy.conf
COPY configs/nginx-server-proxy.conf.template /etc/nginx/templates/server-proxy.conf.template
COPY configs/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY configs/headscale_config.yaml /etc/headscale/config.yaml
COPY scripts /scripts
RUN chmod +x /scripts/*.sh

COPY --chmod=664 .GIT_REV /etc/

EXPOSE 80 443 8091 8092 2379 2380

HEALTHCHECK CMD /scripts/healthcheck.sh

ENTRYPOINT ["/scripts/entrypoint.sh"]
CMD ["/scripts/auto-entry.sh"]
