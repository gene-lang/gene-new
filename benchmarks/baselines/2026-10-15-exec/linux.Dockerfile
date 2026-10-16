FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git pkg-config xz-utils \
    libcurl4-openssl-dev libpcre3 libsqlite3-dev libncurses-dev libssl-dev \
    openssl zlib1g-dev python3 nodejs && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/nim.tar.xz https://nim-lang.org/download/nim-2.2.12-linux_arm64.tar.xz \
    && echo '3dc04191af72a8310cf1c8ffb6f772cc3716fc5f264bc7c453ab4aecb4085221  /tmp/nim.tar.xz' | sha256sum -c - \
    && tar -xJf /tmp/nim.tar.xz -C /opt && rm /tmp/nim.tar.xz
ENV PATH=/opt/nim-2.2.12/bin:$PATH
WORKDIR /work
