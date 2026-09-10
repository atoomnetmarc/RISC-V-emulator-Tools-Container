# riscv-emulator-tools-container

Container image for generating and running RISC-V Architectural Certification Tests (ACT4) against [the RISC-V emulator](https://atoomnet.net/projects/risc-v-emulator). Bakes in the ACT4 framework, the Sail reference simulator (RV32 + RV64), the UDB gems, the Python venv and the xPack `riscv-none-elf-gcc` bare-metal toolchain (symlinked to the `riscv64-unknown-elf-*` names). All versions are pinned via Dockerfile ARGs.

The emulator (DUT) is not part of the image: the host builds it with PlatformIO and mounts it at `/emulator` at runtime. The ACT repository wraps this via `scripts/act_container.sh` — see that repository's README for day-to-day usage.

## Build

```bash
podman build -t riscv-emulator-tools-container .
```

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
