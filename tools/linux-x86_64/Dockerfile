# Linux x86_64 qualification image for the native-app profile.
# Building gene needs a C toolchain and ncurses headers (the terminal UI).
# The runtime loads libpcre (Nim std/re) at startup and libcurl, libsqlite3,
# and libcrypto on first use; the other -dev packages serve the C-backed genex
# packages and test adapters.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates cmake curl git pkg-config xz-utils \
      libcurl4 libcurl4-openssl-dev libpcre3 libsqlite3-0 libsqlite3-dev \
      libncurses-dev libssl-dev openssl zlib1g-dev \
      python3 nodejs \
    && rm -rf /var/lib/apt/lists/*

ARG NIM_VERSION=2.2.4
ARG NIM_SHA256=791802138aaf19c8579232c50b4998ce2ae2928b791127ce5b4ef3c7af53fb46
RUN curl -fsSL -o /tmp/nim.tar.xz \
      https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz \
    && echo "${NIM_SHA256}  /tmp/nim.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/nim.tar.xz -C /opt \
    && rm /tmp/nim.tar.xz
ENV PATH=/opt/nim-${NIM_VERSION}/bin:$PATH

# Ubuntu 24.04 is older than three genex pins: libuv (1.48 against
# genex/libuv_timer's 1.52.x), utf8proc (pkg-config 3.0.0 against genex/archive's
# >=3.1.0), and libcurl (8.5 against genex/websocket's 8.11+ WebSocket API).
# These upstreams publish signatures rather than digests; the hashes below
# were recorded from the release tarballs.
ARG LIBUV_VERSION=1.52.1
ARG LIBUV_SHA256=66d511b9e6e334c0e62279eb234fbfb2b3110b1479c09b95b44c7afca8cff9e7
RUN curl -fsSL -o /tmp/libuv.tar.gz \
      https://dist.libuv.org/dist/v${LIBUV_VERSION}/libuv-v${LIBUV_VERSION}.tar.gz \
    && echo "${LIBUV_SHA256}  /tmp/libuv.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/libuv.tar.gz -C /tmp \
    && cmake -S /tmp/libuv-v${LIBUV_VERSION} -B /tmp/libuv-build \
         -DCMAKE_BUILD_TYPE=Release -DLIBUV_BUILD_TESTS=OFF \
    && cmake --build /tmp/libuv-build -j \
    && cmake --install /tmp/libuv-build && ldconfig \
    && rm -rf /tmp/libuv.tar.gz /tmp/libuv-v${LIBUV_VERSION} /tmp/libuv-build

# The Makefile, as distro packages use: its pkg-config Version is the library
# SO version (3.2.3 here), which genex/archive's ">=3.1.0" pin expects. The
# CMake build reports the release number (2.11.3) instead.
ARG UTF8PROC_VERSION=2.11.3
ARG UTF8PROC_SHA256=abfed50b6d4da51345713661370290f4f4747263ee73dc90356299dfc7990c78
RUN curl -fsSL -o /tmp/utf8proc.tar.gz \
      https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v${UTF8PROC_VERSION}.tar.gz \
    && echo "${UTF8PROC_SHA256}  /tmp/utf8proc.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/utf8proc.tar.gz -C /tmp \
    && make -C /tmp/utf8proc-${UTF8PROC_VERSION} -j"$(nproc)" install \
         prefix=/usr/local && ldconfig \
    && rm -rf /tmp/utf8proc.tar.gz /tmp/utf8proc-${UTF8PROC_VERSION}

# A separate prefix, like Homebrew's keg-only curl on macOS: the gene runtime
# keeps loading Ubuntu's libcurl, and only the genex/websocket test opts in
# with GENE_PKG_CONFIG_PATH=/opt/curl/lib/pkgconfig and
# LD_LIBRARY_PATH=/opt/curl/lib.
ARG CURL_VERSION=8.19.0
ARG CURL_SHA256=4eb41489790d19e190d7ac7e18e82857cdd68af8f4e66b292ced562d333f11df
RUN curl -fsSL -o /tmp/curl.tar.xz \
      https://curl.se/download/curl-${CURL_VERSION}.tar.xz \
    && echo "${CURL_SHA256}  /tmp/curl.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/curl.tar.xz -C /tmp \
    && cd /tmp/curl-${CURL_VERSION} \
    && ./configure --prefix=/opt/curl --with-openssl --without-libpsl \
         --disable-manual --disable-docs \
    && make -j"$(nproc)" && make install \
    && cd / && rm -rf /tmp/curl.tar.xz /tmp/curl-${CURL_VERSION}

# The SERVICE workload pins its proxy (tests/profiles/native-app/service/proxy.lock.json).
ARG CADDY_VERSION=2.11.2
ARG CADDY_SHA512=2513b289054386b76642a9e8bfc10d217df2b5361e4cdd0c72672b0eeab57ae737d57466eb70f1a44233cbcc697ecf21de88137ca45ef4b64f150a32b58f5f14
RUN curl -fsSL -o /tmp/caddy.tar.gz \
      https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz \
    && echo "${CADDY_SHA512}  /tmp/caddy.tar.gz" | sha512sum -c - \
    && tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy \
    && rm /tmp/caddy.tar.gz

WORKDIR /work
