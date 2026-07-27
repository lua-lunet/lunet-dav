# Builder: compiles the whole lunet stack from source via xmake for whatever
# platform this build targets (no dependency on a specific release tarball
# arch — this stage builds natively for the host's default platform).
FROM debian:trixie-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive
ARG LUNET_VERSION=v0.4.3

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        build-essential \
        pkg-config \
        libpq-dev \
        libsodium-dev \
        libuv1-dev \
        lua5.1 \
        liblua5.1-0-dev \
        luajit \
        libluajit-5.1-dev \
        luarocks \
        xmake \
        cargo \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
ENV XMAKE_ROOT=y

RUN git clone --depth 1 --branch "${LUNET_VERSION}" https://github.com/lua-lunet/lunet lunet-src \
    && cd lunet-src \
    && xmake f -m release --lunet_trace=n --lunet_verbose_trace=n -y \
    && xmake build lunet \
    && xmake build lunet-bin \
    && xmake build lunet-postgres \
    && mkdir -p /out/bin/lunet \
    && find / -xdev -name lunet-run -exec cp {} /out/bin/lunet-run \; \
    && find / -xdev -name lunet.so -exec cp {} /out/bin/lunet.so \; \
    && find / -xdev -name postgres.so -exec cp {} /out/bin/lunet/postgres.so \;

# lnt_shared: Rust crate not in the release archives; built from the same
# lunet source tree (see docs/DESIGN.md §12.0).
RUN cd lunet-src/ext/lnt_shared \
    && cargo build --release \
    && cp lnt_shared.lua /out/bin/lunet/lnt_shared.lua \
    && cp target/release/liblnt_shared.so /out/bin/lunet/liblnt_shared.so

# cjson, built via luarocks against the system Lua 5.1 headers (loads fine under LuaJIT)
RUN luarocks --lua-version=5.1 install lua-cjson --tree=/out/luarocks \
    && cp /out/luarocks/lib/lua/5.1/cjson.so /out/bin/cjson.so

# Runtime: only the shared libraries the vendored .so files link against
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 \
        libsodium23 \
        libuv1 \
        libluajit-5.1-2 \
        lua-expat \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sodium_lib="$(ldconfig -p | grep -m1 libsodium.so | awk '{print $NF}')" \
    && ln -s "$sodium_lib" "$(dirname "$sodium_lib")/libsodium.so"

WORKDIR /app

COPY --from=builder /out/bin ./bin
COPY . .

RUN mkdir -p target \
    && lxp_arch="$(dpkg -L lua-expat | grep '/lua/5\.1/lxp\.so$' | head -1)" \
    && test -n "$lxp_arch" \
    && ln -sf "$lxp_arch" /app/bin/lxp.so \
    && mkdir -p /app/bin/lxp \
    && ln -sf /usr/share/lua/5.1/lxp/lom.lua /app/bin/lxp/lom.lua

ENV LUA_PATH="/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;./app/?.lua;./lib/?.lua;./compat/?.lua;./bin/?.lua;./?.lua"
ENV LUA_CPATH="./bin/?.so;./bin/lunet/?.so;"

# Database config is supplied at run time: docker run --env-file .env
# 0.0.0.0 so the container's port mapping can reach the server (server.lua
# defaults to 127.0.0.1, correct for bare-metal local dev but not for a
# container's isolated network namespace). lunet-run refuses to bind
# non-loopback addresses unless told the container boundary is the intended
# security perimeter.
ENV LUNET_HOST=0.0.0.0
EXPOSE 8081

CMD ["./bin/lunet-run", "--dangerously-skip-loopback-restriction", "server.lua"]
