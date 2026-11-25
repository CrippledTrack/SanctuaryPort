# arm64 and native macOS: options

Status: **planning.** Nothing here is built yet. `docs/macos.md` records how the Windows x64 build
was brought up under CrossOver (Rosetta 2) on an Apple A18 Pro (branch `macos-crossover-bringup`).

## What ties the port to x86-64 today

The port runs the PS4 game's x86-64 code directly on the host CPU. On an arm64 Mac, Rosetta 2
translates the **whole x86_64 process**, game code included. There is no supported way for an arm64
process to hand x86 code to Rosetta. Everything else depends on this:

| Dependency | Where | Size |
|---|---|---|
| Guest code calls host functions directly with the System V x86-64 ABI | `ABI __attribute__((sysv_abi))` on every HLE export; 274 native bindings, ~650 imports | all of `src/runtime_*.c` (~13k lines of C) |
| Host calls into guest code (thread entry, callbacks) | `probe.c` `enter_on_stack`, `compat_win.c` (inline x86 asm) | small |
| Guest FP/SSE state | `runtime_thread.c` (`ldmxcsr`, `fldcw`) | small |
| Rewrites of the game's x86 code | `fs`→`gs` TCB loads (`link_modules.py`), ISA rewrite and emulation (`isa_rewrite.*`, `isa_emulate.*`), red-zone trampolines (`redzone.cpp`, Zydis), the game patches (`patches/`, x86 bytes found by signature) | large; done before the code runs |
| Faults handled by reading x86 register state | GPU write tracking (`gpu/shim/sanctuary_write_log.cpp`, `sanctuarygpu.cpp`), red zones, `probe.c` | medium |
| x86 JIT inside the GPU core | `shader_recompiler/ir/passes/flatten_extended_userdata_pass.cpp` (xbyak, 32 MB code generator) | one pass |
| Not tied to x86 | the shadPS4 video core in general, Vulkan, SDL, audio, file and save code | most of `gpu/` |

One thing already fits Apple silicon: the runtime's guest page size is 16 KiB (`PAGE` in
`runtime_memory.c`), the same as macOS on arm64.

## Options

### A. Native macOS x86_64 build under Rosetta (no Wine)

Build the POSIX (Linux) path for macOS as an x86_64 app. Rosetta still translates everything, so
this does **not** reach arm64. It does remove Wine:
- `MACOS-TEMP` becomes `#ifdef __APPLE__`.
- The TCB slot becomes a real pthread key, since macOS x86_64 keeps per-thread data at `gs:8*key`.
- Mach/BSD memory calls replace the Linux ones.

- **For:** smallest step to "runs on macOS directly". Rosetta is the best x86→arm translator on a
  Mac, with hardware TSO memory ordering that third-party code cannot enable. It gives a fair
  baseline to measure anything else against.
- **Against:** still needs an x86_64 Vulkan driver (the self-built KosmicKrisp) or a separate arm64
  GPU process, and it depends on Rosetta's future. Apple said in 2025 that general Rosetta support
  ends after macOS 27, keeping a subset for older games; check the current wording.

### B. arm64 host with an embedded dynamic translator (JIT)

The runtime, GPU core, SDL and audio are built natively for arm64. Game code runs through an
x86-64 → arm64 JIT inside the same process.
- Candidates: **FEXCore** (FEX-Emu's CPU core: x86-64 + AVX, TSO handling, C++) or **box64's
  dynarec** (already used as Wine's in-process x64 emulator on ARM64, "wowbox64").
- Neither targets macOS today. Both are built around Linux signals and syscalls, and FEX assumes
  4 KiB host pages.
- Calls into the 274 native bindings / HLE exports become thunks (System V registers → AAPCS64,
  almost one to one). Host→guest calls re-enter the JIT. Fault handlers have to map faults in
  translated code back to guest state.
- **For:** works on macOS arm64, Windows on ARM and Linux arm64 from one design. No up-front analysis
  of the game's code.
- **Against:** porting a JIT that is not built for macOS. Without hardware TSO, x86 memory ordering
  costs barriers on every load and store. Expect it to be slower than Rosetta on a Mac.

### C. arm64 host with static recompilation of the game

Translate the game image (eboot + the linked `libc.prx`, `libSceFios2.prx`, `libSceNpToolkit2.prx`)
ahead of time into C or LLVM IR, then compile it for arm64. This is the "recomp" approach.
- The project already does much of the needed analysis:
  - function discovery (`function_starts.py`: 62456 starts in Diablo III);
  - decoding with Zydis;
  - patches located by signature, applied before translation;
  - import linking (`link_modules.py`).
- Still needed:
  - lifting x86-64 with SSE/AVX/F16C/BMI (the Jaguar instruction set) to IR;
  - indirect branches and jump tables through a lookup table of known function starts;
  - an x86 register/flags model for the guest's own C++ unwinder;
  - memory ordering (conservative acquire/release or barriers on shared accesses).
- **For:** best long-term performance, no JIT, and one output for macOS arm64, Windows on ARM,
  Linux arm64 and possibly Android. It fits the project's tools.
- **Against:** the largest up-front effort. Missing even one indirect-branch target breaks the game.
  Each game update needs a new recompile, though patches by signature already handle the
  updates' code changes.

### D. Windows on ARM (not macOS)

The current x64 build may already run on Snapdragon PCs under Prism. An ARM64EC build would run the
runtime natively, with only the game code emulated, in-process. This is a separate target and does
not help macOS.

## Suggested order

1. **Measure the CrossOver run.** Check frame rate, CPU time per thread and rendering correctness in
   the run from `docs/macos.md`. This is the bar for everything else.
2. **A, native macOS x86_64**, as the macOS deliverable. It turns `MACOS-TEMP` into real macOS code
   and drops Wine (and the TLS-slot borrowing). It is mostly the Linux POSIX path.
3. **Spike B vs C** for arm64, each with a measurable target, before committing to either:
   - **C spike:** lift a small set of hot, self-contained game functions, chosen from a profile.
     Run the lifted arm64 versions against the native x86 ones under Rosetta on the same inputs,
     and compare results and speed.
   - **B spike:** build FEXCore (or box64's dynarec) on macOS arm64. Run a small x86-64 test
     program that calls into a native arm64 "HLE" function and back.
   - **Decide on:** speed against Rosetta, how much of the game image the method covers, and the
     work it implies for the ~650 imports and the fault handlers.
4. Replace the GPU core's x86 JIT pass (xbyak) with an interpreter or `xbyak_aarch64` whichever way
   arm64 goes. It is small and independent.
