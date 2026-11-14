# ACT container patches

The image pins ACT 4.1.0. Two source patches adapt the framework to the emulator. Both patches are temporary: an ACT upgrade may make them unnecessary.

## 1. Trap signature region in the Zaamo U-mode source

File: `tests/priv/ExceptionsSvZaamo/sv32_exceptions_Zaamo_Umode.S`

Patch: `patches/trap-sigupd-count-zaamo-umode.patch`

Change: `TRAP_SIGUPD_COUNT` 110 -> 270.

Reason: the sail reference model overflows the 110-entry trap signature region. 270 matches the sibling ExceptionsSv source.

Applied by: `git apply` in the Dockerfile.

## 2. Identity map ahead of the S-mode switch

File: `tests/env/rvtest_setup.h`

Patch: `patches/identity-map-ahead-of-smode.patch`

Change: the patch places the `rvtest_identity_map` block directly after `RVTEST_BOOT_TO_MMODE`, ahead of the `RVTEST_BOOT_TO_SMODE` call.

Reason: the S-mode prolog enables `satp` with an empty root page table. The identity-map PTE is written by code that runs in S-mode. The first S-mode fetch faults on the empty table, and the S-mode handler faults in the same unmapped region, which produces a trap loop. The patch writes the PTE in M-mode, where `satp` has no effect.

Applied by: `git apply` in the Dockerfile.

## Upgrade note

Both patches target ACT 4.1.0. Check each patch against the new ACT tag. Remove a patch when the upstream source contains the fix.
