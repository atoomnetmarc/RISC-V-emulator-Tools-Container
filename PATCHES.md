# ACT container patches

The image pins ACT `act4` commit `1c3e9f2a89e103eeed0a3e6ba1bc699f100fd481`. The commit sizes the trap signature region per test chunk: the default is 0, the privileged generator reserves 1500 entries, and assembly tests link with a 128-byte stack. The image applies one temporary source patch.

## Trap handler xEPC advance without ZCA

File: `tests/env/rvtest_trap_handler.h`

Patch: `patches/trap-handler-width-without-zca.patch`

Change: the `adj_<mode>epc_rtn` block always uses the instruction-width detection. The `#ifdef ZCA_SUPPORTED` guard and the `li T2, 4` fallback are removed.

Reason: a misaligned fetch has a 2-byte-aligned `xEPC`. The handler must advance to the next instruction boundary. The fixed 4-byte advance skips the instruction at the next 4-byte boundary. The width detection reads the low halfword at `xEPC` and advances 2 or 4. The `lhu` is safe because `xEPC` is 2-byte aligned.

Applied by: `git apply` in the Dockerfile.

## Upgrade note

The patch targets the pinned commit. Check the patch against a new commit and remove it when the upstream source contains the fix.
