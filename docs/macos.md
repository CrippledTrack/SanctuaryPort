# macOS

Status: **the game runs natively** (no Wine) as an x86_64 macOS build under Rosetta 2, with an x86_64
build of KosmicKrisp (Mesa's Vulkan driver on Metal 4). The Windows build under CrossOver also ran
(run 6 below), but that route is no longer supported: its Wine-specific code was removed. Performance, rendering correctness and long sessions have not been measured
yet. The native build is described first. The rest of the file is the history: the baseline (the
unmodified Windows release under CrossOver) and each blocker found on the way.

## Native macOS build (x86_64, Rosetta 2)

```bash
bash packaging/macos/deps.sh     # x86_64 libraries into out/macos-deps (sources: see the script)
bash packaging/macos/build.sh    # out/macos/sanctuary-probe, out/macos/lib/*.dylib
SANCTUARY_GAME_DIR=~/d3/CUSA00242-app SANCTUARY_PATCH_DIR=~/d3/CUSA00242-patch \
  SANCTUARY_KOSMICKRISP_ICD=<x86_64 KosmicKrisp>/share/vulkan/icd.d/kosmickrisp_mesa_icd.x86_64.json \
  python3 -u run.py
```

Needs Homebrew `cmake ninja pkg-config glslang boost robin-map vulkan-headers` and the x86_64
KosmicKrisp build (see "KosmicKrisp built for x86_64 from source"; not yet scripted).

What macOS needs, in one place. All of it is compile-time `#ifdef SANCTUARY_MACOS`, which
`gpu/CMakeLists.txt` defines for every target of a macOS build (a build without it stops with an
`#error`). Windows and Linux builds contain none of it, and there is no run-time macOS check.
Upstream shadPS4 platform code keeps `__APPLE__`.

| Need | How |
|---|---|
| Guard `0x0fc0000000`–`0x7000000000` | user range from `0x7000000000`; LOW capped below the guard (`runtime_memory.c`) |
| Host allocations landing in guest ranges | SYSTEM, LOW and USER reserved at start, as on Windows; unmapping puts a reservation back |
| No `memfd_create` | unlinked `shm_open` object; released pages zeroed through the pool view (no hole punching) |
| `gs` cannot be moved | the guest TCB lives in a pthread key: macOS x86_64 keeps per-thread data at `gs:[8*key]`, and the loader rewrites `gs:[0]` loads to that slot (`patch_tcb_loads`, as on Windows) |
| **Heap objects must sit below 1 TiB** (the game packs pointers into 40 bits) | mimalloc takes over the process's malloc as the default zone, confined to `0xfc00000000`–`0x10000000000` (`src/macos_heap.c`); system libraries' allocations land there too |
| Write faults arrive as **SIGBUS** | the GPU write-tracking handler takes SIGBUS as well as SIGSEGV |
| Signal contexts | `src/host_ucontext.h`: `HOST_GREGS(uc)[REG_*]` over Linux gregs or the macOS thread state |
| **AppKit windows only on the main thread** | the loader and game run on a 16 MiB thread; the main thread runs `CFRunLoopRun()` (not `dispatch_main()`, which ends the main thread) and the GPU library sends the window loop to the main queue |
| Window surface | a Metal window (`SDL_Metal_CreateView`), Vulkan surface through `VK_EXT_metal_surface` |
| Rosetta hides AVX in CPUID | `ROSETTA_ADVERTISE_AVX=1` (run.py), before the process starts |
| shadPS4 forced its own `VK_DRIVER_FILES` | kept only when the caller set none |
| No sparse binding | dense buffer arenas of 16 MiB, merged when a request spans several (see "Memory footprint") |
| Guard wastes BDA page-table entries | the table skips `0x0fc0000000`–`0x7000000000` (`BdaIndex`, `get_bda_pointer`) |
| glibc extras | `src/compat_mac.{h,c}`, `gpu/shim/sanctuary_mac_compat.h`: timed locks, `clock_nanosleep`, `getrandom`, `RUSAGE_THREAD`, `gettid`, `st_*tim`, sockets; epolls use `poll()` as on Windows |

Checks before the build (a native x86_64 test program under Rosetta): the guest ranges reserve, `shm`
views alias, `gs:[8*key]` reads the key in two threads, written code runs and can be patched, and a
protected-page write from a red-zone leaf function arrives as SIGBUS with the right address, `rip` and
write bit, resumes, and keeps the red zone. A second test program got every malloc in the low
region, CoreFoundation's and a second thread's included.

Result (native run 4): window, swapchain and presenter, guest threads, a 2 GiB dense arena at
`0x7000000000`, save data mounted. No STOP or assertion after 5000+ log lines. The process uses
~210% CPU and a ~5.2 GB physical footprint on this 8 GB Mac, now ~2.9 GB (see "Memory footprint").

Not done yet:
- frame rate, rendering correctness, audio, gamepads and a long session;
- the in-world footprint (~7 GB, see "Memory footprint");
- scripting and packaging the KosmicKrisp build and a `.app`;
- `build.sh --test`'s unit tests on macOS;
- `--gamepad` mode, which pumps SDL events off the main thread.

Linux and native Windows have not been rebuilt since these changes.

## Memory footprint

Measured with `footprint -p` and `vmmap -v` on the running process, after ~2 minutes (intro and
menus; no gameplay yet). The footprint counts dirty pages, compressed or swapped ones included.

| | before | after |
|---|---|---|
| Process footprint | 5193 MB | 2926 MB |
| Dense buffer arenas (GPU) | 2048 MiB | 320 MiB |
| BDA page table (GPU) | 225 MiB | 48 MiB |
| GPU page-state table | 512 MiB | touched pages only (malloc heap 671 → 133 MB) |
| Guest memory pool (game data) | ~1 GB | ~1 GB |

What changed:
- **Dense arenas of 16 MiB** (`buffer_cache.cpp`). KosmicKrisp counts a whole allocation once the GPU
  uses it, so one 2 GiB arena cost 2 GiB for ~160 MiB of resident guest memory. With 16 MiB pages
  a request that spans pages merges their arenas (`MergeDenseArenas`): a new arena, resident blocks
  copied on the GPU, page-table entries rewritten, the old memory freed after in-flight work. The
  largest request seen is 147 MiB. `SANCTUARY_DENSE_ARENA_MB` picks another page size.
- **The BDA page table skips the macOS guard.** It is indexed by guest block from address 0, and the
  user range starts at 448 GiB, so 225 MiB of it covered the guard. `BdaIndex()` on the CPU and the
  `get_bda_pointer` shader function subtract the gap (`Profile::bda_gap_start/end`); a page inside
  it reads out of bounds, the same fault as an empty entry.
- **The page manager's state table** (one entry per 4 KiB page of the 40-bit space, 512 MiB) was a
  value-initialized `std::array`, so every page of it was written at start. It is now mapped
  straight from the OS (`mmap` / `VirtualAlloc`). `calloc` did not help: mimalloc zeroed it.
  This applies to every platform.
- `Runtime: flexible maps=...` now ends with `released=` (pool bytes released and zeroed on macOS).
  It is 0 in these runs, so `host_discard`'s memset costs nothing so far.

In-world (10 minutes in Act 2, 2026-11-24): rendering correct, 69 arena merges, no stops, but the
footprint settles at ~6.7 GB and ends at 7.2 GB:

| | in-world |
|---|---|
| Guest memory pool | 2.3 GB |
| Dense buffer arenas | 1296 MiB allocated for 746 MiB resident (16 MiB pages: ~1.7×) |
| Images (texture cache) | ~475 MiB |
| BDA page table | 48 MiB |
| Other GPU allocations (not yet identified: 2×256 MiB, several 128–192 MiB, ~50×16 MiB) | ~1.9 GB |
| Host malloc heap | ~310 MB |

The ~1.9 GB, identified (2026-11-25, menus with a hero loaded, `SANCTUARY_VRAM_REPORT=2`):
- **Merged dense arenas leaked.** A merge freed the old arenas' memory but kept their `VkBuffer`s (so
  pointers stay valid), and KosmicKrisp keeps memory alive while a buffer bound to it exists. Every
  merge kept its predecessors: 832 MiB in the menus, exactly the sum of the freed arenas. The deferred
  free now destroys the `VkBuffer` first; memory outside VMA and the arenas fell from 1017 MiB to
  185 MiB.
- **The rest of the driver's memory is small:** 185 MiB for ~125 pipelines, command buffers and
  the like.
- **Arena pages are now 4 MiB.** With 16 MiB pages the arenas held 800 MiB for 442 MiB resident;
  8 MiB: 648 for 478; 4 MiB: 540 for 440 (29 merges instead of 17).
- VMA itself (~900 MiB): images ~330 MiB, staging rings 160 MiB (10 × 16 MiB), the stream buffer
  128 MiB, other buffers ~90 MiB, the BDA table 48 MiB.

`SANCTUARY_VRAM_REPORT=2` prints, every 30 s, device usage split into VMA (blocks and what is
allocated in them), arenas and what lies outside both, and live pipelines;
`SANCTUARY_VRAM_DUMP=<prefix>` also writes VMA's per-allocation JSON (allocations are named:
`buf <type> <name>`, `img WxHxD <format>`, `presenter frame`, ...).

Menu footprint with the same save data: ~5.5–5.9 GB before these two changes, ~4.7–5.0 GB after
(GPU ~2.0 GB, guest memory ~2.0 GB, host heap ~0.25 GB). Not yet measured in-world.

## Baseline: Windows release under CrossOver (2026-11-24)

History from here on. Of the `MACOS-TEMP` patches below, the user-range move and dense arenas live on
as `#ifdef SANCTUARY_MACOS` code in the native build; the Wine host check (`runtime_wine_on_macos`) and the
TEB slot 63 borrow were removed with CrossOver support, so the Windows build no longer runs there.

| | |
|---|---|
| Machine | Apple A18 Pro (5 GPU cores, Metal 4), 8 GB RAM |
| macOS | 27.2.1 (26B131) |
| Translation | Rosetta 2 (x86-64 → arm64) |
| Wine | CrossOver 26.3 (Wine 11.0), new `win10_64` bottle `SanctuaryPort` |
| Graphics | Vulkan through MoltenVK (CrossOver bundles one; the probes did not print which copy or version loaded). GPTK's D3DMetal is not involved: the port emits Vulkan, not Direct3D. |
| Build | `SanctuaryPort-windows.zip` v0.7.5 (sha256 `2ae4816f…786338`, matches the release) |
| Game | US CUSA00242 1.00 + 1.47 update read in place (`SANCTUARY_GAME_DIR`, `SANCTUARY_PATCH_DIR`) |

Commands (from the extracted release folder):

```bash
CX=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin
$CX/cxbottle --bottle SanctuaryPort --create --template win10_64
$CX/wine --bottle SanctuaryPort "$PWD/bin/sanctuary-probe.exe" --cpu-features
$CX/wine --bottle SanctuaryPort "$PWD/bin/sanctuary-gpu-capabilities.exe"
$CX/wine --bottle SanctuaryPort "$PWD/bin/sanctuary-probe.exe" --vulkan-only
SANCTUARY_GAME_DIR='Z:\Users\<you>\d3\CUSA00242-app' SANCTUARY_PATCH_DIR='Z:\Users\<you>\d3\CUSA00242-patch' \
  WINEDEBUG=-all $CX/wine --bottle SanctuaryPort "$PWD/python/python.exe" -u run.py
```

### Results

| Stage | Result |
|---|---|
| `--cpu-features` | ✅ `CPU: complete`. Rosetta exposes every instruction set the game needs; no ISA rewrite. |
| `sanctuary-gpu-capabilities` | ✅ `Apple A18 Pro supports live presets` |
| `--vulkan-only` | ✅ `Apple A18 Pro; command submission + 4096-byte readback PASS` |
| `run.py`: game, update, patches, linking | ✅ update layered in place, `Patches: CUSA00242 01.47`, libc / Fios2 / NpToolkit2 linked, 62456 function starts, frame rate 60 |
| `run.py`: runtime start | ❌ `STOP: reserving the PS4 address range (link with --disable-high-entropy-va) failed at 0000001000000000 (+0xec00000000), error 487` |

It stops before any window or GPU work, so there is no performance figure yet.

### Why it stops

`runtime_memory_reserve` (`src/runtime_memory.c`) reserves the guest ranges as placeholders, at their
PS4 addresses:

| Range | Addresses | |
|---|---|---|
| SYSTEM | `0x04_0000_0000`–`0x08_0000_0000` | reserved fine |
| LOW | `0x08_0000_0000`–`0x10_0000_0000` | not reserved up front; host-owned blocks (image, stacks, trampolines) are allocated on demand, upward from `LOW_MIN` (`VirtualAlloc` on Windows) |
| USER | `0x10_0000_0000`–`0xFC_0000_0000` | **fails**: ERROR_INVALID_ADDRESS |

On this macOS **every process** has a region that cannot be changed: `vmmap` shows it as
`Guard fc0000000-7000000000 [385.0G] ---/--- SM=NUL`. Native arm64 processes have it too, as do
Rosetta x86-64 processes and the Wine process (checked with `/bin/sleep`, `arch -x86_64 /bin/sleep`
and a Wine `notepad`). So it comes from the OS, not from Wine or CrossOver. It covers:

- the top 1 GB of LOW (`0x0F_C000_0000`–`0x10_0000_0000`);
- the first 384 GB of USER (`0x10_0000_0000`–`0x70_0000_0000`).

`0x70_0000_0000`–`0xFC_0000_0000` (560 GB) is free. Rosetta, the Wine loader (load address
`0x2_0000_0000`) and the system libraries all sit below `0x2_2000_0000`, so they do not collide with
the port's ranges.

**This applies to a native macOS build as well**, not just to Wine. Any macOS route needs the guest
layout to avoid `0x0F_C000_0000`–`0x70_0000_0000`.

### Patch: user range above the guard (`MACOS-TEMP`)

This patch is the first one; it is verified only up to the reservation, and nothing past it has
run. `src/runtime_memory.c` now asks Wine's `ntdll!wine_get_host_version` for the host. When it reports
`Darwin`, the user range starts at `0x70_0000_0000` instead of `0x10_0000_0000`; native Windows and
Linux keep the PS4 layout (by construction; not run on either since the change). Each changed
spot is marked `MACOS-TEMP` (`grep -n MACOS-TEMP src/runtime_memory.c`). **Swap it to macOS-only**
(`#ifdef __APPLE__`, no Wine check) once there is a native macOS build. While macOS is tested
with the Windows build, the check has to happen at run time.

- LOW is unchanged. Only its last 1 GB falls in the guard: the allocator walks upward and skips
  addresses where `VirtualAlloc` fails, so at most that 1 GB is lost (not measured).
- A guest `MAP_FIXED` into `0x10_0000_0000`–`0x70_0000_0000` would now stop with
  `guest range outside the reservation`. This is untested: no guest code has run yet.

Result with the patched `sanctuary-probe.exe` (cross-built on this Mac, see below):

```
Runtime: Wine on macOS, PS4 user range starts at 0x7000000000 (macOS guard below it)
STOP: no TEB TLS slot below 64 (got 74)
```

The reservation now succeeds. The next blocker follows straight after it.

### Next blocker: no free TEB TLS slot

The runtime keeps the guest TCB pointer in one of the 64 TEB `TlsSlots` (`gs:0x1480 + 8*slot`),
because patched guest code loads it with a single `gs:`-relative instruction
(`src/runtime_thread.c`, `runtime_thread_tcb_offset`; `src/probe.c`, `patch_tcb_loads`). Slots 64
and above live behind a pointer (`TlsExpansionSlots`), which one load cannot follow.

Under CrossOver on macOS, **slots 0–64 are already taken before `main`**. A minimal program
(kernel32 and the UCRT only) gets `TlsAlloc() == 65`. Loading the game's DLLs adds only a few more
(user32 +1, shell32 +1, avcodec +1, swscale +1, avformat +3), so the DLLs are not the cause. All 64
`TlsSlots` read zero in a fresh process: Wine reserves them rather than filling them. Why is not
confirmed. A guess is that macOS's own pthread thread-specific data shares the `gs` segment (keys at
`gs:8*key`; `TlsSlots` would be keys 656–719), and Wine keeps those away from Windows code.

Tested (small test programs cross-built with the same toolchain, run in the bottle):
- **A `gs:`-relative load reaches the TEB.** Writing `TEB+0x1480+8*63` through the `NtCurrentTeb()`
  pointer reads back through `gs:`, and the reverse also works. This holds in the main thread and
  in a `CreateThread` thread.
- **Slot 63 keeps its value** across `Sleep`, a file open and loading `vulkan-1.dll`, in both
  threads.

Options:
1. On Wine/macOS, use a reserved slot that is still empty (for example 63). The tests above make
   this a real candidate. The remaining risk: if something on the macOS side writes that slot
   later, the guest TCB is silently overwritten.
2. First confirm in Wine's macOS code why the slots are reserved and whether anything ever writes
   them. That would settle the risk in option 1.
3. Choose another per-thread TEB field that Wine on macOS leaves alone, reachable with one `gs:`
   load.

### Patch: guest TCB borrows TEB slot 63 (`MACOS-TEMP`)

Option 1 was taken. `src/runtime_thread.c`: when `TlsAlloc` returns a slot ≥ 64 and
`runtime_wine_on_macos()` (now shared, `src/runtime.h`) is true, the TCB uses slot 63. It is
written straight into `TEB+0x1480+8*63`, because the process does not own that slot, so
`TlsSetValue` is not used. It is marked `MACOS-TEMP` and needs a fresh look for native macOS. The
remaining risk is as stated above.

Result (run 3):

```
Runtime: Wine on macOS, PS4 user range starts at 0x7000000000 (macOS guard below it)
Runtime: Wine on macOS, no free TEB TLS slot; guest TCB borrows slot 63
Runtime: /app0 reads the update, then Z:\Users\<you>\d3\CUSA00242-app
Window: Windowed
GPU 0: Apple A18 Pro (IntegratedGpu)
Vulkan 1.3 is required, but only 1.2 is supported by device!
STOP: GPU library assertion failed (see GPU log above)
```

The runtime now gets past the TLS setup, opens its window and stops at GPU setup.

### Next blocker: MoltenVK reports Vulkan 1.2

The GPU core (shadPS4's `vk_instance.cpp`) asserts Vulkan 1.3. CrossOver 26.3's
`lib64/libMoltenVK.dylib` is **x86_64** and reports 1.2 for the A18 Pro. Homebrew's `molten-vk`
1.4.2 is **arm64-only**, so the x86_64 Wine process under Rosetta cannot load it.

Options:
1. A newer MoltenVK with an x86_64 slice (KhronosGroup MoltenVK releases or the LunarG Vulkan SDK
   ship universal builds), loaded in place of CrossOver's. Try `DYLD_LIBRARY_PATH` first, so the
   CrossOver app is not modified.
2. Relax the 1.3 requirement on Wine/macOS when the features the port uses (dynamic rendering,
   synchronization2, maintenance4, …) are present as extensions on 1.2. This is port work in
   `gpu/`.

### MoltenVK 1.4.2 through a clone of CrossOver's support folder

Option 1 was taken. `DYLD_LIBRARY_PATH` **does not work**. CrossOver's `bin/wine` is a
`/usr/bin/perl` script, and `/usr/bin/perl` is SIP-protected, so `DYLD_*` is dropped. Starting
`bin/wineloader` directly does not help either: `wineloader` and `lib/wine/x86_64-unix/wine` are
signed with the hardened runtime (`flags=0x10000(runtime)`) and lack
`com.apple.security.cs.allow-dyld-environment-variables`, so dyld ignores `DYLD_*`. They do have
`disable-library-validation`, so they load a MoltenVK that CrossOver did not sign.
`win32u.so` loads MoltenVK as `dlopen("libMoltenVK.dylib")`, resolved through its rpath
`@loader_path/../../../lib64`.

What works without changing `/Applications/CrossOver.app`: an APFS clone of its support folder
(929 MB, instant, shares blocks) with only `lib64/libMoltenVK.dylib` replaced by the universal
build from KhronosGroup's `MoltenVK-macos.tar` v1.4.2
(sha256 `f95765a6…c4024e`, checked):

```bash
cp -cR /Applications/CrossOver.app/Contents/SharedSupport/CrossOver ./cx-mvk
cp MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib ./cx-mvk/lib64/
MVK_CONFIG_LOG_LEVEL=2 ./cx-mvk/bin/wine --bottle SanctuaryPort ...   # same bottle
```

A small test program reports `Apple A18 Pro: Vulkan 1.3.357, driver 0x28a2` (MoltenVK 1.4.2; Wine
caps the version at 1.3). With the stock CrossOver it reports `Vulkan 1.2.290, driver 0x27e2`
(MoltenVK 1.2.10). Stop the stock `wineserver` (`wineserver -k`) before switching between the two
trees.

Result (run 4):

```
GPU: using Apple A18 Pro
GPU: guest multisampling on
Required Vulkan feature unavailable: robustBufferAccess2
STOP: GPU library assertion failed (see GPU log above)
```

### Next blocker: robustness2 features

`gpu/shadps4/video_core/renderer_vulkan/vk_instance.cpp` (`CreateDevice`) asserts all three
`VK_EXT_robustness2` features. MoltenVK 1.4.2 on the A18 Pro under Wine reports:

| Feature | |
|---|---|
| `robustBufferAccess` (core 1.0) | 1 |
| `robustBufferAccess2` | **0** |
| `robustImageAccess2` | 1 |
| `nullDescriptor` | **0** |

These features emulate the PS4 GPU behaviour where an out-of-bounds read returns zero, and they
allow empty descriptor slots. Dropping the assertion needs replacements in the GPU core:
- **`nullDescriptor`:** bind dummy buffers and images wherever a null descriptor is used.
- **`robustBufferAccess2`:** fall back to `robustBufferAccess`, which clamps instead of returning
  zero, or add bounds checks in the generated shaders.

This is port work in `gpu/`, not macOS packaging.

**KosmicKrisp** (LunarG's Mesa Vulkan driver on Metal 4) enables all three features. Mesa main
`src/kosmickrisp/vulkan/kk_physical_device.c` sets `robustBufferAccess2`, `robustImageAccess2` and
`nullDescriptor` to `true`, and the driver supports `VK_EXT_metal_surface`, which CrossOver's
`win32u.so` uses. Two obstacles:
- LunarG ships it for **Apple Silicon only**; its macOS SDK says it "will not load" on x86_64. The
  Wine process is x86_64 under Rosetta, so it would need an x86_64 build from Mesa source, which is
  unsupported upstream. Metal itself works under Rosetta.
- It exports only `vk_icdGetInstanceProcAddr`, while CrossOver loads `libMoltenVK.dylib` and needs
  `vkGetInstanceProcAddr`. The fix is to put an x86_64 Khronos Vulkan loader in the clone as
  `libMoltenVK.dylib` and point it at KosmicKrisp with `VK_DRIVER_FILES`. That is an ordinary
  variable, so the hardened runtime keeps it.

### KosmicKrisp built for x86_64 from source

Both obstacles were solved and it **runs under Rosetta**. Built from Mesa main (`4f29b71`,
2026-11-25):

1. Native arm64 build with Homebrew LLVM 23.1.6 (needed for Mesa's OpenCL-C kernels). It produces
   `mesa_clc`, `vtn_bindgen2` and `kk_clc`, plus an arm64 KosmicKrisp. About 40 s.
2. x86_64 cross-build with Apple clang `-arch x86_64`, `-Dmesa-clc=system
   -Dprecomp-compiler=system -Dllvm=disabled` (the stage-1 tools on `PATH`), and
   `pkg_config_libdir = ['/nonexistent']` so Homebrew's arm64 libraries are not picked up.
3. Khronos Vulkan-Loader `v1.4.363` with `-DCMAKE_OSX_ARCHITECTURES=x86_64`.

```bash
# stage 1 (in a venv with meson, mako, pyyaml, packaging)
meson setup build-arm64 -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= \
  -Dopengl=false -Dglx=disabled -Degl=disabled -Dgles1=disabled -Dgles2=disabled \
  -Dllvm=enabled -Dinstall-mesa-clc=true -Dinstall-precomp-compiler=true -Dxmlconfig=disabled
# stage 2 (cross file: clang/objc with -arch x86_64, host_machine x86_64-darwin)
meson setup build-x64 --cross-file x86_64-darwin.ini -Dplatforms=macos -Dvulkan-drivers=kosmickrisp \
  -Dgallium-drivers= -Dopengl=false -Dglx=disabled -Degl=disabled -Dgles1=disabled -Dgles2=disabled \
  -Dllvm=disabled -Dmesa-clc=system -Dprecomp-compiler=system -Dxmlconfig=disabled
# a CrossOver clone with the x86_64 loader standing in for MoltenVK
cp -cR /Applications/CrossOver.app/Contents/SharedSupport/CrossOver ./cx-kk
cp libvulkan.1.4.363.dylib ./cx-kk/lib64/libMoltenVK.dylib
VK_DRIVER_FILES=.../kosmickrisp_mesa_icd.x86_64.json ./cx-kk/bin/wine --bottle SanctuaryPort ...
```

Test programs under Wine report `Apple A18 Pro: Vulkan 1.4.368` and
`robustBufferAccess=1 robustBufferAccess2=1 robustImageAccess2=1 nullDescriptor=1`.

Result (run 5): the robustness2 check passes, and these optional extensions are reported missing
(warnings only): `depth_range_unrestricted`, `custom_border_color`, `vertex_input_dynamic_state`,
`fragment_shader_barycentric`, `shader_atomic_float2`, `image_view_min_lod`,
`compute_shader_derivatives`, `shader_clock` and the AMD/NV vendor extensions. Then:

```
CreateDevice: The GPU has no queue with sparse binding (required).
Could not create a Vulkan device on Apple A18 Pro: ...
```

### Next blocker: sparse binding

The buffer cache (`gpu/shadps4/video_core/buffer_cache/`) maps guest memory through "arena" buffers
created with `eSparseBinding | eSparseResidency` and filled with `bindSparse`
(`BufferCache::SubmitPendingArenaBinds`). This came with the shadPS4 video core in the first import
(`5d04046`); it is shadPS4's design, not a SanctuaryPort addition. There is no fallback, and
`vk_instance.cpp` requires a sparse-binding queue.

No Vulkan driver on Metal offers it today:
- **MoltenVK 1.4.2:** no sparse support.
- **KosmicKrisp (Mesa main):** `kk_buffer.c` says the sparse flags are something it does not
  "support yet", and its queues do not advertise sparse binding. Metal 4 does have sparse heaps
  (`mtl_heap.m` already sets `sparsePageSize`), so it may come later.

Options:
1. **GPU core:** a non-sparse arena path. Use one large ordinary buffer per arena page (BDA
   still works), or allocate arena pages up front instead of binding them on demand. This is a deep
   change to the buffer cache and the fault manager.
2. **Driver:** add sparse buffer binding to KosmicKrisp on top of Metal 4 sparse heaps. This means
   Mesa driver work, possibly worth sending upstream.
3. **Wait** for KosmicKrisp to add sparse support.

### Patch: dense buffer arenas (`MACOS-TEMP`)

Option 1, in its smallest form. It applies only when `Vulkan::SanctuaryMacosHost()` is true (now:
`runtime_wine_on_macos()`; later `#ifdef __APPLE__`) **and** the driver has no
`sparseResidencyBuffer`. Elsewhere the sparse path is unchanged.

- `vk_instance.cpp`: without a sparse-binding queue on macOS, the graphics queue stands in and
  `Instance::UsesDenseArenas()` is set. Everywhere else it is still a hard error.
- `buffer.h/.cpp`: `MemoryType::DenseArena`, a plain buffer that `Buffer::BindDenseArenaMemory`
  binds and whose device address it reads.
- `buffer_cache.cpp`: `BindDenseArena` allocates each arena's full size with `vkAllocateMemory`
  (bypassing VMA's budget) when the arena is created. `EnsureResident` then only writes the
  page-table entries (no allocation, no `bindSparse`). The probe in the constructor drops the
  sparse flags.
- **Merging two arenas is not implemented.** A request spanning two arena pages stops with
  `STOP: dense buffer arenas (macOS) cannot merge: ...`. Sparse binding merges by rebinding the same
  memory; a dense merge would need a content copy, new page-table entries and freeing the old
  arenas.

Why dense seemed affordable: a test program that bound a 4 GiB device-local buffer moved the
process footprint from 36 MB to 40 MB. That holds only until the GPU uses the buffer: in the game
the whole 2 GiB arena counted as dirty (see "Memory footprint"), so dense arenas now use 16 MiB pages. The device
reports `sparseBinding=0`, one queue family (`0x7`), `maxBufferSize` 4096 MiB and one 5461 MiB heap
whose only memory type is device-local, host-visible, coherent and cached. Arena pages are 2 GiB here
(limited by `maxBufferSize`).

Result (run 6): the game starts and runs. `GPU: dense buffer arena 0x7000000000-0x7080000000
(2048 MiB; 2048 MiB in all)` is the only arena so far, with no merge stop. Guest direct memory is
mapped from `0x7000000000` up (the moved user range), and no fixed mapping landed in the macOS guard.
Not checked yet: rendering correctness, frame rate, memory use over a long session, and how a
spanning request would behave.

### Direction

(Written during the CrossOver work; since done.) The native macOS x86_64 build under Rosetta
replaced CrossOver: `MACOS-TEMP` became `#ifdef SANCTUARY_MACOS`, and the TCB slot comes from a
pthread key, since macOS keeps per-thread data at `gs:8*key`. Native arm64 is a separate, larger project. The guest x86-64 code would need an
x86-64 → arm64 translator inside an arm64 process, because Rosetta only translates whole
processes. It is still the long-term target if Rosetta's general availability ends after macOS 27,
as Apple announced in 2025 (check Apple's current wording).

### Building the Windows runtime on macOS

`packaging/windows/cross-build.sh` works on Apple silicon with Homebrew LLVM:

```bash
brew install llvm lld cmake ninja pkg-config glslang zstd
PATH=/opt/homebrew/opt/llvm/bin:$PATH SSL_CERT_FILE=/etc/ssl/cert.pem bash packaging/windows/cross-build.sh
```

- `SSL_CERT_FILE` is needed only when `python3` is python.org's build without its certificates
  installed.
- `cross-toolchain.cmake` now passes `--target=x86_64-w64-mingw32` to `llvm-windres`. Without it,
  the `.res` files come out arm64 on an arm64 host and lld refuses to link them.

### Later

- Rerun this baseline once the TLS slot is solved. The next likely limits are MoltenVK features,
  then memory (8 GB RAM against the 16 GB recommended).
