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
    build-essential cmake git curl opam libgmp-dev zlib1g-dev pkg-config \
    ruby-full ruby-bundler python3 z3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Cached opam tarballs between builds
RUN --mount=type=cache,target=/root/.opam/download-cache,sharing=locked \
    opam init --disable-sandboxing -y \
    && opam switch create "${OCAML_SWITCH}" \
    && eval "$(opam env)"

# Sail compiler
RUN git clone --depth 1 --branch "${SAIL_TAG}" https://github.com/rems-project/sail.git /tmp/sail \
    && eval "$(opam env)" \
    && cd /tmp/sail \
    && opam install . --deps-only -y \
    && dune build --release \
    && dune install

# sail-riscv model (compiled C simulator, RV32 + RV64)
RUN git clone --depth 1 --branch "${SAIL_MODEL_TAG}" https://github.com/riscv/sail-riscv.git /tmp/sail-riscv \
    && eval "$(opam env)" \
    && cd /tmp/sail-riscv \
    && DOWNLOAD_GMP=FALSE ./build_simulator.sh

# ACT4 framework + UDB gems + Python venv (self-contained, no runtime network)
RUN git clone --depth 1 --branch "${ACT_TAG}" https://github.com/riscv/riscv-arch-test.git /opt/riscv-arch-test
RUN cd /opt/riscv-arch-test/framework/src/act/data \
    && bundle config set path vendor/bundle \
    && bundle install
RUN curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin UV_UNMANAGED_INSTALL=1 sh
RUN cd /opt/riscv-arch-test \
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
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
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

COPY --from=builder /tmp/sail-riscv/build/c_emulator /opt/sail-riscv/build/c_emulator
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
