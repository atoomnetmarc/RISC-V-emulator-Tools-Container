# ACT container image (riscv-tools v2)
#
# Generates and runs RISC-V Architectural Certification Tests (ACT4) against
# the RISC-V emulator. Build once; ACT (opam-free runtime, Sail simulator,
# UDB gems, Python venv) is ready to go.
#
# The emulator (DUT) is NOT part of this image: the host builds it with
# PlatformIO and mounts it at /emulator at runtime.

# Pinned versions
ARG SAIL_TAG=0.20.2
ARG SAIL_MODEL_TAG=0.10
ARG ACT_TAG=4.0.0
ARG OCAML_SWITCH=5.5.0
ARG XPACK_GCC_VERSION=15.2.0-1.1
# Ubuntu package mirror (e.g. http://nl.archive.ubuntu.com/ubuntu)
ARG UBUNTU_MIRROR=http://archive.ubuntu.com/ubuntu

# ---------------------------------------------------------------------------
# Stage 1: builder — opam, Sail compiler, sail-riscv model, ACT4 + gems + venv
# ---------------------------------------------------------------------------
FROM ubuntu:26.04 AS builder

ARG SAIL_TAG
ARG SAIL_MODEL_TAG
ARG ACT_TAG
ARG OCAML_SWITCH
ARG UBUNTU_MIRROR

# Switch to a (local/fast) Ubuntu mirror before installing packages
RUN sed -i -e "s|http://archive.ubuntu.com/ubuntu|${UBUNTU_MIRROR}|g" \
           -e "s|http://security.ubuntu.com/ubuntu|${UBUNTU_MIRROR}|g" \
           /etc/apt/sources.list.d/ubuntu.sources

# Cached apt archives + partial/ dir (missing in ubuntu:26.04)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    mkdir -p /var/cache/apt/archives/partial \
    && apt-get update \
    && apt-get -o APT::Keep-Downloaded-Packages=true install -y --no-install-recommends \
    build-essential cmake git curl opam libgmp-dev zlib1g-dev pkg-config ccache \
    ruby-full ruby-bundler python3 z3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The whole opam root (OCaml switch, packages, installed Sail) lives in a cache
# mount: it is only needed inside the builder stage, so nothing is lost from the
# image. Steps with cache mounts are never layer-cached, so everything here must
# be idempotent: init/switch only run when missing, the Sail clone is reused and
# dune rebuilds incrementally. -j lets opam build independent packages in
# parallel.
RUN --mount=type=cache,target=/root/.opam,sharing=locked \
    --mount=type=cache,target=/tmp/sail,sharing=locked \
    opam init --disable-sandboxing -j"$(nproc)" -y \
    && if opam switch list --short 2>/dev/null | grep -qx "${OCAML_SWITCH}"; then \
         opam switch set "${OCAML_SWITCH}"; \
       else \
         opam switch create "${OCAML_SWITCH}" -j"$(nproc)"; \
       fi \
    && eval "$(opam env)" \
    && if [ ! -d /tmp/sail/.git ] || [ "$(git -C /tmp/sail describe --tags 2>/dev/null)" != "${SAIL_TAG}" ]; then \
         find /tmp/sail -mindepth 1 -delete \
         && git clone --depth 1 --branch "${SAIL_TAG}" https://github.com/rems-project/sail.git /tmp/sail; \
       fi \
    && cd /tmp/sail \
    && opam install . --deps-only -y -j"$(nproc)" \
    && dune build --release \
    && dune install

# sail-riscv model (compiled C simulator, RV32 + RV64). The checkout and build
# tree are cache-mounted so Sail codegen and CMake rebuild incrementally; ccache
# avoids recompiling unchanged C/C++ sources. The finished c_emulator is copied
# out of the cache mount into the image layer so stage 2 can COPY it.
RUN --mount=type=cache,target=/root/.opam,sharing=locked \
    --mount=type=cache,target=/tmp/sail-riscv,sharing=locked \
    --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    if [ ! -d /tmp/sail-riscv/.git ] || [ "$(git -C /tmp/sail-riscv describe --tags 2>/dev/null)" != "${SAIL_MODEL_TAG}" ]; then \
      find /tmp/sail-riscv -mindepth 1 -delete \
      && git clone --depth 1 --branch "${SAIL_MODEL_TAG}" https://github.com/riscv/sail-riscv.git /tmp/sail-riscv; \
    fi \
    && eval "$(opam env)" \
    && cd /tmp/sail-riscv \
    && cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo \
         -DDOWNLOAD_GMP=FALSE -DENABLE_RISCV_TESTS=TRUE \
         -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    && cmake --build build -j"$(nproc)" \
    && rm -rf /opt/sail-riscv-build \
    && cp -a build /opt/sail-riscv-build

# ACT4 framework + UDB gems + Python venv (self-contained, no runtime network)
RUN git clone --depth 1 --branch "${ACT_TAG}" https://github.com/riscv/riscv-arch-test.git /opt/riscv-arch-test
# Ruby gems: downloaded gems are kept in a cache mount so repeated builds only
# install (fast) instead of downloading
RUN --mount=type=cache,target=/root/.bundle-cache,sharing=locked \
    cd /opt/riscv-arch-test/framework/src/act/data \
    && bundle config set path vendor/bundle \
    && bundle config set cache_path /root/.bundle-cache \
    && bundle install
RUN curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin UV_UNMANAGED_INSTALL=1 sh
# Python packages: uv cache mount avoids re-downloading wheels
RUN --mount=type=cache,target=/root/.cache/uv,sharing=locked \
    cd /opt/riscv-arch-test \
    && UV_PYTHON_DOWNLOADS=never uv sync --frozen --python /usr/bin/python3

# ---------------------------------------------------------------------------
# Stage 2: runtime — lean: toolchain, sail simulator, ACT clone, gems, venv
# ---------------------------------------------------------------------------
FROM ubuntu:26.04

LABEL org.opencontainers.image.source=https://github.com/atoomnetmarc/RISC-V-emulator-Tools-Container \
      org.opencontainers.image.description="Container image for generating and running RISC-V Architectural Certification Tests (ACT4) against the RISC-V emulator" \
      org.opencontainers.image.licenses=Apache-2.0

ARG ACT_TAG
ARG XPACK_GCC_VERSION
ARG UBUNTU_MIRROR

# Switch to a (local/fast) Ubuntu mirror before installing packages
RUN sed -i -e "s|http://archive.ubuntu.com/ubuntu|${UBUNTU_MIRROR}|g" \
           -e "s|http://security.ubuntu.com/ubuntu|${UBUNTU_MIRROR}|g" \
           /etc/apt/sources.list.d/ubuntu.sources

# RISC-V bare-metal toolchain via xpm (ACT4 requires GCC >= 15). Every
# riscv-none-elf-* binary is additionally exposed under the
# riscv64-unknown-elf-* name used by the ACT configs and elf2bin.sh.
# xpm tarball cache: the ~100 MB RISC-V toolchain archive is only downloaded once
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/root/.cache/xpm,sharing=locked \
    mkdir -p /var/cache/apt/archives/partial \
    && apt-get update \
    && apt-get -o APT::Keep-Downloaded-Packages=true install -y --no-install-recommends \
    nodejs npm make python3 ruby-full ruby-bundler libgmp10 git z3 \
    && rm -rf /var/lib/apt/lists/* \
    && npm install --global xpm \
    && xpm install --global "@xpack-dev-tools/riscv-none-elf-gcc@${XPACK_GCC_VERSION}" \
    && bin_dir="$(find /root/.local/xPacks -type f -name 'riscv-none-elf-gcc' -printf '%h\n' | head -n1)" \
    && for f in "$bin_dir"/riscv-none-elf-*; do \
         base="$(basename "$f")"; suffix="${base#riscv-none-elf-}"; \
         case "$suffix" in *[0-9]*) continue ;; esac; \
         ln -s "$f" "/usr/local/bin/riscv64-unknown-elf-$suffix"; \
       done

COPY --from=builder /opt/sail-riscv-build/c_emulator /opt/sail-riscv/build/c_emulator
COPY --from=builder /opt/riscv-arch-test /opt/riscv-arch-test
COPY --from=builder /usr/local/bin/uv /usr/local/bin/uv
# UDB downloads the z3 shared library the first time it runs; the builder
# already did, so the runtime never needs to fetch it
COPY --from=builder /root/.cache/udb /root/.cache/udb

# Runtime paths baked as ENV — no entrypoint.sh. Each is overridable per run
# (podman run -e ...).
ENV ACT_DIR=/opt/riscv-arch-test \
    SAIL_BIN=/opt/sail-riscv/build/c_emulator \
    BUNDLE_GEMFILE=/opt/riscv-arch-test/framework/src/act/data/Gemfile \
    PATH=/opt/sail-riscv/build/c_emulator:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LOG_DIR=/opt/riscv-arch-test/work/test-all \
    UV_FROZEN=1 \
    UV_NO_SYNC=1 \
    ACT_VERSION=${ACT_TAG}

# The emulator is mounted from the host at runtime:
#   podman run -v <RISC-V-emulator-Native>:/emulator ...
# ACT outputs flow through the mounted /opt/riscv-arch-test/work.
WORKDIR /act
