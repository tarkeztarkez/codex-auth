FROM debian:bookworm-slim AS build
ARG ZIG_VERSION=0.16.0
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && case "${TARGETARCH}" in \
         amd64) ZIG_ARCH=x86_64; ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;; \
         arm64) ZIG_ARCH=aarch64; ZIG_SHA256=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;; \
         *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && curl -fsSLo /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm -rf /var/lib/apt/lists/* /tmp/zig.tar.xz
ENV PATH=/opt/zig:${PATH}
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
RUN case "${TARGETARCH}" in amd64) ZIG_ARCH=x86_64 ;; arm64) ZIG_ARCH=aarch64 ;; *) exit 1 ;; esac \
    && zig build -Doptimize=ReleaseSafe -Dtarget=${ZIG_ARCH}-linux-musl

FROM alpine:3.23
RUN apk add --no-cache curl && addgroup -S codex-auth && adduser -S -G codex-auth codex-auth \
    && mkdir -p /data && chown codex-auth:codex-auth /data
COPY --from=build /src/zig-out/bin/codex-auth /usr/local/bin/codex-auth
USER codex-auth
ENV PORT=8080 DATA_DIR=/data
VOLUME ["/data"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD curl --fail --silent http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["codex-auth", "server"]
