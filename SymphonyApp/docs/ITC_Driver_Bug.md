# HEKA ITCMM Driver Bug — Technical Documentation

## Overview

The HEKA ITC-18 (and ITC-1600) DAQ hardware is controlled through the `ITCMM.dll` native driver library, which is installed to `C:\WINDOWS\System32\`. This driver was originally written for 32-bit Windows and later recompiled for 64-bit. However, the 64-bit version retains **internal 32-bit pointer arithmetic** that causes crashes when the DLL or its heap allocations reside above the 4 GB virtual address boundary.

This bug is latent — it does not manifest on all machines or with all software configurations. It became a critical problem during the Symphony 3 migration due to changes in how MATLAB R2024b and the .NET CLR manage virtual address space.

---

## The Bug

### Root Cause

`ITCMM.dll` internally uses 32-bit pointer arithmetic in several code paths, most critically in:

- `ITC_OpenDevice` — device handle allocation
- `ITC_ReadWriteFIFO` — data transfer buffer management
- `ITC18_InitializeCustom` — hardware initialization

When the DLL is loaded above the 4 GB boundary (`0x1_0000_0000`), pointers returned by Windows heap functions (`HeapAlloc`, `malloc`) are 64-bit values. The driver truncates these to 32 bits, resulting in null or invalid pointer dereferences.

### Crash Signature

All crashes share a consistent register pattern:

| Register | Value | Meaning |
|----------|-------|---------|
| RAX | `0x0000000000000000` | Null — truncated pointer |
| R8 | `0x0000000000004E20` | 20,000 = 2× sample rate (10 kHz) |
| RCX | `0x00000000XXXX0020` | Device memory + 0x20 offset |
| R11 | `0x00000000XXXX0000` | Device memory base |
| RIP | `ITCMM.dll+00167661` | Consistent crash offset |

The crash occurs at `ITC18_InitializeCustom+14077`, called from `ITC_ReadWriteFIFO+979`. The offset is constant across all crashes, confirming a specific code path with hardcoded 32-bit pointer handling.

### Affected Function: `ITC_ReadWriteFIFO`

The `ITCChannelDataEx` struct contains a `DataPointer` field (type `void*`). When the driver processes this pointer internally, it truncates the upper 32 bits:

```
Full pointer:      0x0000017A_0C5C44A0  (above 4 GB)
After truncation:  0x00000000_0C5C44A0  (invalid — maps to wrong memory)
```

If the truncated address happens to be `0x00000000`, the crash is a null pointer dereference. If it maps to a valid but wrong memory region, the crash may be a data corruption or access violation at a different location.

---

## Why This Worked in Symphony 2

Symphony 2 used the following architecture:

```
MATLAB (R2016/R2017) → .NET Framework 4.5 → C++/CLI HekaIOBridge.dll → ITCMM.dll
```

### Key Differences

1. **C++/CLI Bridge**: `HekaIOBridge.dll` was a **mixed-mode assembly** — part managed (.NET), part native C++. When loaded via `NET.addAssembly`, the Windows loader resolved `ITCMM.dll` as an **implicit native dependency** immediately. This happened very early in the MATLAB session, when the low virtual address space was still available.

2. **Older MATLAB**: MATLAB R2016/R2017 had a much smaller memory footprint. Java, the .NET CLR, and MATLAB's own libraries consumed less virtual address space, leaving room below 4 GB for `ITCMM.dll`.

3. **Older .NET CLR**: The .NET Framework 4.5 CLR reserved a smaller GC heap region compared to newer versions.

### Symphony 3 Architecture

```
MATLAB (R2024b) → .NET Framework 4.8 → Pure C# HekaNativeInterop.dll → [DllImport] → ITCMM.dll
```

The critical change: `HekaNativeInterop.dll` is a **pure C# assembly** with no native dependencies. `ITCMM.dll` is loaded **lazily** via P/Invoke — only when the first `[DllImport("ITCMM.dll")]` function is called (e.g., `ITC_Devices()`). By this time:

- MATLAB R2024b has loaded Java 1.8, its graphics engine, and many internal DLLs
- The .NET CLR 4.0 (from .NET Framework 4.8) has reserved its GC heap
- The low virtual address space below 4 GB is largely occupied

When `ITCMM.dll` is finally loaded, the OS relocates it above 4 GB — triggering the bug.

### Timing Diagram

```
Symphony 2 (C++/CLI):
  MATLAB starts → NET.addAssembly(HekaIOBridge.dll)
                  → Windows loader loads ITCMM.dll NOW
                  → Low address space still free
                  → ITCMM.dll at 0x1E270000 ✓ (below 4 GB)
  ... later: ITC calls work

Symphony 3 (P/Invoke):
  MATLAB starts → NET.addAssembly(HekaNativeInterop.dll)
                  → Pure .NET, no native deps loaded
  ... Java loads, CLR allocates GC heap, UI renders ...
  User selects Heka rig → First P/Invoke call → ITCMM.dll loaded NOW
                  → Low addresses occupied
                  → ITCMM.dll at 0x278C71A0000 ✗ (above 4 GB)
  ... ITC calls crash
```

---

## Failed Approach: Porting the C++/CLI Bridge

Before developing the P/Invoke workaround, we first attempted to port the original C++/CLI `HekaIOBridge.dll` from Symphony 2 to the modern toolchain. The original bridge was built with Visual C++ 10 (Visual Studio 2010) targeting .NET Framework 4.0/4.5.

### The Porting Challenge

The C++/CLI language underwent breaking changes between Visual C++ 10 and modern Visual C++ (2019/2022). The most significant was the deprecation of the managed `array` keyword in favor of `cli::array`:

```cpp
// Visual C++ 10 (original HekaIOBridge)
array<short>^ data = gcnew array<short>(nsamples);

// Modern Visual C++ (2019/2022)
cli::array<short>^ data = gcnew cli::array<short>(nsamples);
```

All managed array declarations throughout the HekaIOBridge codebase required this translation, along with other modernization changes for the newer C++/CLI compiler.

### Why the Ported Bridge Failed

After completing the `array` → `cli::array` translation and updating the project to build with the modern toolchain, the ported bridge compiled successfully but **failed at runtime with the same ITC driver crashes**. The ported C++/CLI DLL, when loaded by MATLAB R2024b's .NET CLR, did not provide the same early-loading behavior as the original:

1. **Different CLR hosting**: MATLAB R2024b hosts .NET Framework 4.8 (CLR 4.0 with updates), which manages DLL loading differently than the older MATLAB + .NET 4.5 combination.
2. **Different load timing**: Even with the C++/CLI bridge as a mixed-mode assembly, the modern CLR's DLL resolution and ASLR behavior placed `ITCMM.dll` above 4 GB.
3. **Recompilation side effects**: The modern compiler generated different native code layout in the mixed-mode assembly, potentially changing the order and timing of native dependency resolution.

This failure confirmed that the bug was not specific to P/Invoke vs C++/CLI — it was fundamentally about **when** `ITCMM.dll` gets loaded relative to the process's virtual address space consumption. The old Symphony 2 worked because of a fortunate combination of older MATLAB, older .NET, and the specific memory layout of that era — not because of any inherent advantage of the C++/CLI bridge.

This understanding led us to the multi-layered workaround approach (ASLR mitigation, early pre-loading, struct alignment correction) rather than continuing to pursue the C++/CLI bridge path.

---

## Machine-Specific Behavior

The bug is machine-specific because the virtual address layout depends on:

| Factor | Dev Machine | Target Machine |
|--------|-------------|----------------|
| ITCMM.dll address | `0x180000000` (above 4 GB) | `0x180000000` (above 4 GB) |
| Device handle | `0x1C250C40` (below 4 GB) | `0x2214FF10B30` (above 4 GB) |
| Result | **Works** | **Crashes** |

On the dev machine, even though `ITCMM.dll` itself was above 4 GB, its internal heap allocations (including the device handle) happened to land below 4 GB. On the target machine, the process heap was also above 4 GB, causing all internal allocations to be in the high address range.

Factors that affect this:
- **Windows version**: Windows 10 vs 11 (different thread schedulers and ASLR behavior)
- **MATLAB update version**: R2024b Update 7 vs Update 8 (different `hdf5.dll` and internal libraries)
- **CPU architecture**: Hybrid cores (Intel 13th/14th gen) vs older Xeon (naturally serializes threads differently)
- **ASLR entropy**: Windows Exploit Protection settings

---

## Struct Alignment Issue

In addition to the address space bug, the P/Invoke struct layout for `ITCChannelInfo` was initially incorrect:

### C# Pack=1 (104 bytes — WRONG)
```
Offset  0: ModeNumberOfPoints (4)
Offset  4: ChannelType (4)
...
Offset 44: ModeParameters (8)   ← IntPtr, no padding
Offset 52: SamplingIntervalFlag (4)
Offset 56: SamplingRate (8)     ← Wrong offset
Total: 104 bytes
```

### Native Default Alignment (112 bytes — CORRECT)
```
Offset  0: ModeNumberOfPoints (4)
Offset  4: ChannelType (4)
...
Offset 44: padding (4)          ← Alignment for IntPtr
Offset 48: ModeParameters (8)   ← Correct offset
Offset 56: SamplingIntervalFlag (4)
Offset 60: padding (4)          ← Alignment for double
Offset 64: SamplingRate (8)     ← Correct offset
Total: 112 bytes
```

The `ITC_SetChannels` call failed with error `0x80651000` ("Wrong command / Mode") because the native driver read `SamplingRate` from offset 64 but our struct had it at offset 56.

**Fix**: Removed `Pack=1` from `ITCChannelInfo` to use default .NET alignment, matching the native C compiler's layout. The `ITCChannelDataEx` struct retains default alignment (24 bytes) for the same reason.

---

## The Workaround

The workaround is multi-layered, addressing both the address space issue and the struct alignment:

### Layer 1: ASLR Mitigation (Windows Exploit Protection)

On machines where `ITCMM.dll` loads above 4 GB, disable high-entropy ASLR for the MATLAB process via an elevated PowerShell command:

```powershell
Set-ProcessMitigation -Name "C:\Program Files\MATLAB\R2024b\bin\win64\MATLAB.exe" `
    -Disable ForceRelocateImages,BottomUp,HighEntropy
```

This must be applied to the actual MATLAB executable. On some installations, the executable is at:
- `C:\Program Files\MATLAB\R2024b\bin\matlab.exe`
- `C:\Program Files\MATLAB\R2024b\bin\win64\MATLAB.exe`
- `C:\Program Files\MATLAB\R2024b\bin\win64\MATLABWindow.exe`

Apply the mitigation to all three to be safe. Verify with:

```powershell
Get-ProcessMitigation -Name "C:\Program Files\MATLAB\R2024b\bin\win64\MATLAB.exe"
```

The ASLR section should show:
```
BottomUp                : OFF
ForceRelocateImages     : OFF
HighEntropy             : OFF
```

### Layer 2: Early DLL Pre-Loading

The `preloadHekaDriver()` function (called from `addAppPaths.m` before any .NET assemblies are loaded) attempts to load `ITCMM.dll` as early as possible:

1. Checks for `ITCMM.dll` in `C:\WINDOWS\System32\`
2. Compiles a MEX helper (`loadDllAtBase.c`) that calls `LoadLibrary("ITCMM.dll")`
3. Loads the DLL before the .NET CLR initializes

This is a best-effort approach — on some machines, the low address space is already occupied even before our code runs. The ASLR mitigation (Layer 1) is more reliable.

### Layer 3: Eager HekaNativeInterop Loading

In `addAppPaths.m`, immediately after loading `Symphony.Core.dll`, the `HekaNativeInterop.dll` assembly is loaded and `EnsureNativeLoaded()` is called:

```matlab
NET.addAssembly(hekaInteropDll);
Heka.NativeInterop.ITCMM.EnsureNativeLoaded();
```

The `EnsureNativeLoaded()` static constructor in the C# `ITCMM` class calls `LoadLibrary("ITCMM.dll")`, anchoring the DLL in the process address space as early as possible after CLR initialization.

### Layer 4: Struct Alignment Correction

The `ITCChannelInfo` and `ITCChannelDataEx` structs use default .NET alignment (no `Pack` attribute), matching the native driver's expected layout:

```csharp
[StructLayout(LayoutKind.Sequential)]  // Default alignment — matches native C compiler
public struct ITCChannelInfo { ... }   // 112 bytes on 64-bit

[StructLayout(LayoutKind.Sequential)]  // Default alignment
public struct ITCChannelDataEx { ... } // 24 bytes on 64-bit
```

### Layer 5: Thread Safety

All ITC hardware calls are serialized through a lock (`_itcLock` in `QueuedHekaHardwareDevice`) to prevent concurrent access:

```csharp
private readonly object _itcLock = new object();

public void StopHardware()
{
    lock (_itcLock)
    {
        ITCMM.ITC_Stop(DevicePtr, IntPtr.Zero);
    }
}
```

This prevents the crash that occurred when `ITC_Stop` was called from the UI thread while `ITC_ReadWriteFIFO` was running on the acquisition thread.

### Layer 6: Diagnostic Logging

The `HekaDaqController.m` constructor logs the `ITCMM.dll` base address and device handle address, providing immediate feedback on whether the workaround is effective:

```
HekaDaqController: ITCMM.dll base address = 0x2B20000 (OK, below 4GB)
```

If the address is above 4 GB, a warning is displayed:

```
Warning: ITCMM.dll loaded at 0x1FED9B90000 (above 4GB). This will likely cause a crash.
```

---

## Verification

### HekaTestConsole

The `HekaTestConsole.exe` (.NET console application) tests the ITC hardware independently of MATLAB:

```cmd
HekaTestConsole.exe bridge    REM Test C++/CLI IOBridge path
HekaTestConsole.exe raw       REM Test direct P/Invoke path
HekaTestConsole.exe all       REM Test all paths
```

The console reports struct sizes, pointer addresses, and pass/fail status for each phase:

```
sizeof(ITCChannelInfo) = 112 bytes (expected 112 for 64-bit)
sizeof(ITCChannelDataEx) = 24 bytes
DeviceHandle=0x1C250C40 (below 4GB) ← OK
```

### Runtime Checks

In MATLAB, verify the DLL load address after initializing a Heka rig:

```matlab
% Check ITCMM.dll location
% The HekaDaqController constructor prints this automatically:
% HekaDaqController: ITCMM.dll base address = 0xXXXXXXXX
```

If the address is above `0x100000000`, apply the ASLR mitigation and restart MATLAB.

---

## Affected Hardware

| Device | Driver DLL | Affected |
|--------|-----------|----------|
| ITC-18 | ITCMM.dll | Yes |
| ITC-1600 | ITCMM.dll | Yes (same driver) |
| ITC-16 | ITCMM.dll | Likely (untested) |

The bug is in `ITCMM.dll` version 22.4.0.0, which is the latest available version from HEKA/Multi Channel Systems. The driver is closed-source and no longer actively maintained.

---

## Definitive Fix: 32-Bit ITC Proxy Process

The workarounds above reduce crash probability but cannot eliminate it entirely. The definitive solution is `HekaITCProxy.exe` — a dedicated **32-bit process** that hosts ITCMM.dll in an address space where all pointers are below 4 GB.

### Architecture

```
64-bit MATLAB/.NET Process              32-bit HekaITCProxy.exe
─────────────────────────               ───────────────────────
HekaDAQController                       ProxyServer (STA thread)
  → ProxiedHekaHardwareDevice             → QueuedHekaHardwareDevice
      → HekaProxyClient                       → ManagedIOBridge
          ─── Named Pipe ─────────────────        → ITCMM.dll (all <4GB)
              (binary protocol)                   → LowMemoryAllocator
                                                  → NativeTimerHelper
```

### How It Works

1. When `HekaDAQController.OpenDevice()` is called, it first checks for `HekaITCProxy.exe` in the assembly directory.
2. If found, it launches the 32-bit process with a dynamically generated named pipe name.
3. The proxy opens the ITC device (with timer resolution reset, STA thread, 100ms settle delay) and returns `GlobalDeviceInfo` over the pipe.
4. All subsequent `IHekaDevice` calls (`ReadWrite`, `ConfigureChannels`, `StartHardware`, `StopHardware`, etc.) are serialized as binary messages over the pipe.
5. The `ReadWrite` hot path uses raw `Buffer.BlockCopy` for short[] arrays — ~12 KB per call at ~4 Hz, with < 5 ms round-trip latency.
6. On rig close, the proxy receives a `Shutdown` message and exits cleanly.

### Why It Works

- **Address space**: A 32-bit process has a 4 GB address limit. Every allocation, including ITCMM.dll's internal heap, is guaranteed below 4 GB. The pointer truncation bug cannot occur.
- **Timer isolation**: MATLAB's `timeBeginPeriod(1)` affects only the MATLAB process. The proxy process maintains the default ~15 ms timer resolution, eliminating the multimedia timer callback race condition.
- **Crash isolation**: If ITCMM.dll crashes in the proxy, only the proxy process dies. MATLAB receives an `IOException` (broken pipe) which is caught and reported as a `HekaDAQException`. MATLAB stays alive.

### Fallback Mode

If `HekaITCProxy.exe` is not found in the assembly directory, `HekaDAQController` falls back to loading ITCMM.dll in-process with the legacy workarounds (ASLR mitigation, timer resolution, struct alignment, thread safety). This ensures backward compatibility with existing deployments.

### Verification

```matlab
% Check if the proxy is running
system('tasklist /fi "imagename eq HekaITCProxy.exe" /fo list')
```

The MATLAB command window shows `[HekaDAQController] Using ITC proxy process (32-bit)` when the proxy is active.

### Files

| File | Project | Description |
|------|---------|-------------|
| `HekaITCProxy.exe` | HekaITCProxy | 32-bit console app (net48, PlatformTarget=x86) |
| `Program.cs` | HekaITCProxy | STA main thread, named pipe server |
| `ProxyServer.cs` | HekaITCProxy | Message dispatch, device lifecycle |
| `HekaProxyClient.cs` | HekaDAQController | Thread-safe named pipe client |
| `ProxiedHekaHardwareDevice.cs` | HekaDAQController | IHekaDevice over pipe |
| `HekaProxyProcessManager.cs` | HekaDAQController | Process lifecycle management |
| `HekaProxyMessageType.cs` | HekaNativeInterop | Wire protocol enum |
| `HekaProxyProtocol.cs` | HekaNativeInterop | Binary serialization helpers |

---

## Future Considerations

1. **MATLAB Version Updates**: The proxy approach is independent of MATLAB's virtual address layout — no adjustment needed for MATLAB updates.

2. **Windows Updates**: The proxy is not affected by Windows ASLR changes. The legacy fallback mode may still need `Set-ProcessMitigation` reapplication after Windows updates.

3. **Driver Replacement**: If HEKA/Multi Channel Systems releases an updated 64-bit driver with proper pointer handling, the proxy can be bypassed by removing `HekaITCProxy.exe` from the deploy directory.

4. **Alternative DAQ Hardware**: For new rig builds, NI-DAQ hardware does not have this bug and is fully supported in Symphony 3 with async read/write and multi-device configurations.
