Good question. Let me lay out the current architecture, the root causes of both issues, and potential solutions ranked by impact and feasibility.

---

## Current Architecture & Pain Points

```
MATLAB Main Thread                    .NET Background Threads
─────────────────                    ──────────────────────
UI events, drawnow                   Controller.ProcessLoop
Data Manager reads ──── hdf5.dll ──── SaveEpoch → H5EpochPersistor
Figure handler updates               CompletedEpoch callbacks
                                     DAQ hardware I/O
```

**The fundamental problem**: MATLAB's `hdf5.dll` is shared between our C# code and MATLAB's own internal operations. Both access it from different threads, and HDF5 is not thread-safe.

---

## Approach 1: Out-of-Process HDF5 Writer (High Impact, Medium Effort)

Move ALL HDF5 operations to a **separate process** that communicates via named pipes or shared memory.

**How it works:**
- A small .NET console app (`SymphonyH5Writer.exe`) handles all HDF5 reads and writes
- The C# `H5EpochPersistor` sends serialized epoch data to the writer process via named pipes
- The writer process has its OWN `hdf5.dll` — completely isolated from MATLAB's copy
- The Data Manager reads from the writer process (not from hdf5.dll directly)

**Benefits:**
- Eliminates the dual-library `abort()` crash entirely
- No ASLR concerns for `hdf5.dll` (separate process, separate address space)
- HDF5 writes can't block the MATLAB UI
- Crash in the writer doesn't crash MATLAB

**Drawbacks:**
- IPC overhead (named pipes add ~0.1ms per call)
- More complex deployment (additional executable)
- Need to handle writer process lifecycle (start/stop/crash recovery)

**Feasibility:** This is the most robust long-term solution. The `Hdf5ThreadDispatcher` we already built is halfway there — replacing the thread dispatch with a process dispatch is a moderate refactor.

---

## Approach 2: Use MATLAB's HDF5 API Instead of C# (High Impact, High Effort)

Instead of calling HDF5 from C#, have MATLAB do ALL file I/O using its built-in `h5create`/`h5write`/`h5read` functions.

**How it works:**
- C# `SaveEpoch` doesn't write to HDF5 directly
- Instead, it queues epoch data (as .NET arrays) for MATLAB to write
- A MATLAB timer or callback writes the data using `h5write`
- All HDF5 calls go through MATLAB's single-threaded execution model

**Benefits:**
- Only one HDF5 library in use (MATLAB's)
- No thread safety issues (MATLAB is single-threaded)
- No `abort()` crashes

**Drawbacks:**
- Major refactor of the persistence layer
- MATLAB's `h5write` is slower than direct C API calls
- Would need to replicate the entire SymphonyHDF5 schema in MATLAB
- Acquisition loop blocked during writes (unless using async MATLAB timers)

**Feasibility:** High effort but eliminates the root cause. Could be done incrementally — start with epoch data, then metadata.

---

## Approach 3: Separate HDF5 DLL for C# (Medium Impact, Low Effort)

Load a **renamed copy** of `hdf5.dll` (e.g., `hdf5_symphony.dll`) for C# P/Invoke calls.

**We already tried this** — it failed because:
1. ITCMM.dll's PE internal module name didn't match the renamed file
2. The DLL's `DllMain` failed when loaded from a non-System32 path
3. P/Invoke resolution is by module name, not file name

**What we could try differently:**
- Use `SetDllDirectory` to temporarily redirect DLL search BEFORE the first P/Invoke call
- Or use `AddDllDirectory` to prepend our directory to the search order
- Or patch the PE header's module name to match the renamed file
- Or build HDF5 from source with a custom library name

**Feasibility:** Medium — requires careful DLL loading sequencing. Building HDF5 from source with a unique name is the most reliable variant.

---

## Approach 4: Minimize HDF5 Contention (Low-Medium Impact, Low Effort)

Reduce the window of time where our C# code and MATLAB's code both touch HDF5.

**Current mitigations (already implemented):**
- Data Manager paused during acquisition (`acquisitionMode = true`)
- `refreshAcquireControls` skipped during acquisition
- `hasOpenEpochGroup` returns cached value during acquisition

**Additional mitigations:**
1. **Batch epoch saves**: Instead of writing each epoch immediately on `CompletedEpoch`, queue them and write in batches during inter-epoch intervals (when the DAQ is idle)
2. **Defer metadata writes**: Write epoch data immediately but defer metadata (properties, keywords, notes) to a post-acquisition flush
3. **Lock MATLAB's HDF5 access**: Before C# writes, call a MATLAB function that "holds" the HDF5 library (e.g., opens and closes a dummy file) to ensure MATLAB's internal state is flushed
4. **Reduce Data Manager queries**: Cache the `GetDataManagerStateAsync` result and only refresh on explicit user request

---

## Approach 5: Move DAQ Pipeline to Separate Process (High Impact, High Effort)

Run the entire C# acquisition pipeline (Controller, DAQController, Persistor) in a separate process.

**How it works:**
- `SymphonyAcquisition.exe` runs independently
- MATLAB communicates via named pipes or gRPC
- The acquisition process has its own .NET runtime, HDF5, and DAQ driver access
- MATLAB is purely the UI — it sends commands and receives epoch data for display

**Benefits:**
- Complete isolation of HDF5, ITCMM.dll, and .NET from MATLAB
- ITCMM.dll address space is fully controlled (can set ASLR per-process)
- Acquisition continues even if MATLAB UI freezes
- Could support headless acquisition (no MATLAB needed)

**Drawbacks:**
- Major architectural change
- IPC latency for streaming figure updates
- Process lifecycle management
- Harder to debug

---

## Approach 6: ITCMM.dll — 32-bit Wrapper Process (Targeted, Medium Effort)

For the ASLR issue specifically: run ITCMM.dll in a **32-bit helper process** where ALL addresses are guaranteed below 4 GB.

**How it works:**
- A small 32-bit .NET or native executable (`HekaITCProxy32.exe`) loads ITCMM.dll
- The main 64-bit MATLAB process communicates with it via named pipes or shared memory
- All ITC function calls are proxied through the 32-bit process

**Benefits:**
- Definitively solves the ITCMM.dll 32-bit pointer bug on ALL machines
- No ASLR workaround needed
- No `Set-ProcessMitigation` required

**Drawbacks:**
- IPC overhead (~0.1ms per call — acceptable for 250ms ProcessInterval)
- Additional process to manage
- Shared memory for FIFO data transfer needs careful design

---

## Recommended Priority

| Priority | Approach | Impact | Effort | Status |
|----------|----------|--------|--------|--------|
| **1** | Minimize HDF5 contention (batch saves, caching) | Medium | Low | ✅ **Done** — batch save queue, background flush threads, Hdf5Lock, Data Manager throttling |
| **2** | Out-of-process HDF5 writer | High | Medium | ⚠️ **Built, disabled** — infrastructure exists (SymphonyH5Writer.exe, named pipes) but not needed since Approach #4 solved the dual-library crash |
| **3** | 32-bit ITCMM proxy process | High | Medium | ✅ **Done** — HekaITCProxy.exe (32-bit) isolates ITCMM.dll. Eliminates ASLR crash and timer callback race. Auto-fallback if exe not found. |
| **4** | Separate HDF5 DLL (renamed copy) | High | Low | ✅ **Done** — `hdf5_symphony.dll` gives C# its own HDF5 instance, eliminating dual-library abort() crashes |
| **5** | Full out-of-process acquisition | Very High | High | ❌ **Not started** — deferred; approaches #1, #3, #4 provide sufficient stability |

### Current State (April 2026)

The HDF5 crash issue is fully resolved by approaches #1 and #4. The ITCMM.dll crash issue is fully resolved by approach #3. Streaming is functional on both Heka (with proxy) and NI-DAQ hardware. The out-of-process acquisition (#5) remains as a future option for headless operation or further isolation.

### Remaining Work

- **Approach #2** (out-of-process HDF5 writer) could be enabled for additional crash isolation, but is currently unnecessary.
- **Approach #5** (full out-of-process acquisition) would enable headless recording and complete fault isolation, but requires significant architectural work.