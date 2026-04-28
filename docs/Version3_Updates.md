# Symphony 3 — Updates & Upgrades

This document summarizes the changes introduced in Symphony 3 relative to Symphony 2. The migration preserved backward compatibility with Symphony 2 data files while modernizing the UI framework, improving performance, and adding new capabilities.

---

## 1. Memory Management & Data Persistence

### Immediate Write to Disk
- Epoch data is now written to the HDF5 file as soon as each epoch completes, rather than accumulating in RAM.
- This significantly reduces memory usage during long recording sessions and provides crash safety — data on disk is preserved even if MATLAB crashes.
- The `_fullData` buffer in the C# `Response` class accumulates all samples for serialization while the display ring buffer keeps only recent data for figure updates.

### Reduced RAM Footprint
- The `Response` class uses a ring buffer (configurable via **Display Chunks** in Options) to limit how much data is held in memory for display purposes.
- The fast `GetDataArray()` / `GetFullDataArray()` C# methods return `double[]` arrays directly to MATLAB, avoiding the slow `IEnumerable<IMeasurement>` marshalling that previously caused freezes at high sample rates (20–50 kHz).
- Response data caches are cleared after each epoch to prevent accumulation.
- Lazy epoch loading in the Data Manager tree — epochs are only loaded when their parent EpochBlock is selected, not on file open.

---

## 2. HDF5 Improvements

### Separate HDF5 Library (`hdf5_symphony.dll`)
- Symphony 3 uses a **renamed copy** of the HDF5 native library (`hdf5_symphony.dll`) for all C# P/Invoke operations. This gives the C# acquisition pipeline its own isolated HDF5 instance, completely separate from MATLAB's built-in `hdf5.dll`.
- Each library instance has its own internal state (file handle table, metadata cache, thread context). This eliminates the `abort()` crashes that occurred when MATLAB and .NET accessed the shared `hdf5.dll` from different threads.
- The `[DllImport("hdf5_symphony")]` declarations ensure the .NET CLR loads the renamed copy instead of finding MATLAB's already-loaded `hdf5` module.
- On macOS/Linux, the standard `hdf5` library name is used (MATLAB's .NET interop doesn't have the same dual-library issue).

### Batch Epoch Save Queue
- Completed epochs are queued in memory during acquisition and flushed to HDF5 on a background thread during inter-epoch intervals.
- This reduces HDF5 write contention by batching writes instead of saving each epoch immediately in the `CompletedEpoch` callback.
- A final flush occurs after `Stop()` waits for all `CompletedEpoch` tasks, ensuring no epochs are lost.
- All background HDF5 writes (streaming `AppendResponseData`, `Flush`, and epoch saves) acquire a global `Hdf5Lock` to prevent concurrent access.

### Live Data Manager During Acquisition
- The Data Manager remains interactive during acquisition — users can click on entities in the tree and view properties while recording.
- Full tree rebuilds are blocked during acquisition (to avoid heavyweight HDF5 enumeration), but incremental updates and entity property reads are allowed.
- A 300ms refresh throttle prevents burst HDF5 reads during rapid state changes.

### Additional HDF5 Improvements
- All HDF5 operations from C# are serialized through a global lock (`Hdf5Lock`) to prevent concurrent access from multiple .NET threads. This includes the streaming writer (`AppendResponseData`, `Flush`, `FinalizeEpoch`), epoch save flushes (`SaveEpoch`), partial saves (`Serialize`), and Data Manager operations (Merge, Split, Delete).
- HDF5 files are opened with `CLOSE_SEMI` degree so `H5Fclose` returns an error (instead of calling `abort()`) when the metadata cache has dirty entries from interrupted background writes.
- Robust error handling around `EndEpochBlock`, `EndEpochGroup`, and `Close` operations — HDF5 handle errors are caught and logged without crashing the application.
- `hasOpenEpochGroup()` results are cached (500ms) to reduce redundant HDF5 queries.

### Lazy Epoch Loading
- The Data Manager state DTO no longer enumerates individual epochs. With 800+ epochs in a file, the previous approach took 3-5 seconds of HDF5 reads on every refresh.
- Epochs are loaded on-demand via `GetEpochsForBlockAsync(blockId)` when the user clicks an epoch block in the tree.
- During acquisition, only expanded block nodes fetch new epochs — typically just the current block.
- This reduces `BuildState()` time from O(groups + blocks + epochs) to O(groups + blocks).

### Out-of-Process HDF5 Writer (Experimental)
- Infrastructure for an out-of-process HDF5 writer (`SymphonyH5Writer.exe`) is built and included in the deployment.
- When enabled, a separate process handles epoch serialization via Named Pipes, providing complete HDF5 isolation.
- Currently disabled by default — the separate HDF5 library approach provides sufficient stability.
- Enable with: `setpref('SymphonyUI', 'outOfProcessWriter', true)` and restart.

### Backward-Compatible File Format
- New H5 files can be opened and read by Symphony 2.
- `PropertyDescriptor` serialization uses `saveobj`/`loadobj` with a plain struct format compatible with both Symphony 2 and 3.
- Description resources (`descriptionType`, `propertyDescriptors`) are written using `getByteStreamFromArray` in the same format Symphony 2 expects.

---

## 3. Streaming & Partial Save

> For comprehensive documentation, see [Streaming.md](Streaming.md).

### Configurable Streaming
- Streaming can be enabled/disabled via **Configure > Options > Streaming** tab.
- **Streaming Threshold**: Epochs longer than the threshold (default: 5 seconds) automatically switch to ring buffer mode, evicting old data from RAM while keeping all data in `_fullData` for HDF5 serialization.
- **Display Chunks**: Controls how many data chunks are kept in the ring buffer for figure display (default: 10, approximately 2.5 seconds at standard ProcessInterval).
- The approximate display window duration is shown in the Options dialog.
- Streaming works on all hardware. With the 32-bit ITC proxy, Heka hardware is fully supported. See [Streaming.md](Streaming.md#hardware-compatibility).

### Partial Epoch Save
- When the user presses **Stop** during a long epoch, a dialog asks whether to **Save Partial**, **Discard**, or **Cancel**.
- Partial epochs are saved to HDF5 with an `isPartial` flag so downstream analysis can identify them.
- Partial save works on both Heka and NI-DAQ hardware (data is serialized from RAM after the hardware stops, regardless of streaming mode).
- At high sample rates (20 kHz+), the first incomplete data epoch is correctly identified for partial save even when multiple epochs are queued.
- The entire partial save path is exception-proof — HDF5 or serialization errors are logged but never crash MATLAB.
- The `requestStopAfterEpoch()` method allows the current epoch to complete naturally and be saved, while `requestStop()` discards incomplete epochs.

### Streaming Figure Handlers
- Figure handlers have a `requiresFullEpoch` property (default: `true`).
- Handlers with `requiresFullEpoch = false` (e.g., `ResponseFigure`, `MeanResponseFigure`) receive live streaming updates during acquisition.
- `epoch.isComplete()` is used to distinguish streaming updates (preview only) from completion callbacks (update mean/analysis). `DisableStreaming()` is called before the `CompletedEpoch` event fires, so `getData()` returns full data in the completion callback.
- `MeanResponseFigure` shows a semi-transparent preview line during streaming (including pre-threshold epochs). On completion, it uses `getFullData()` to compute the proper running mean from all samples.
- `ResponseStatisticsFigure` uses `getFullData()` with bounds checking for robust partial data handling.

---

## 4. Simulated Amplifier Device

- A simulated amplifier device mode allows analog inputs/outputs to not be wasted on a MultiClamp device when not needed.
- Useful for MEA (multi-electrode array) setups and pure simulation rigs where physical amplifier channels are not required.
- Simulated devices are automatically excluded from epoch serialization to avoid saving zero-valued data.

---

## 5. HEKA ITC Driver Bug Fix

> For full technical details, see [ITC_Driver_Bug.md](ITC_Driver_Bug.md).

### 32-Bit Pointer Arithmetic Bug
- The HEKA `ITCMM.dll` driver has internal 32-bit pointer arithmetic that crashes when the DLL or its heap allocations are loaded above the 4 GB virtual address boundary.
- On modern 64-bit Windows with ASLR (Address Space Layout Randomization), this caused intermittent `AccessViolationException` crashes during `ITC_ReadWriteFIFO` and `ITC_OpenDevice`.
- Additionally, ITCMM.dll's internal multimedia timer callback has a race condition that causes access violations when the system timer resolution is 1 ms (as MATLAB sets it). Higher timer frequencies increase crash probability during long epochs.

### Definitive Fix: 32-Bit ITC Proxy Process
- **`HekaITCProxy.exe`** is a dedicated 32-bit process (`PlatformTarget=x86`) that hosts ITCMM.dll where ALL memory addresses are guaranteed below 4 GB.
- The 64-bit MATLAB/.NET host communicates with the proxy via named pipes using a binary protocol (~12 KB/call at ~4 Hz, < 5 ms round-trip).
- The proxy implements the full `IHekaDevice` interface — `HekaDAQController` doesn't know whether it's talking to a local or proxied device.
- ITCMM.dll's multimedia timer runs in the proxy process, completely isolated from MATLAB's timer settings. This eliminates the timer callback race condition.
- The proxy process is launched automatically when a Heka rig is initialized. If `HekaITCProxy.exe` is not found, the system falls back to in-process mode with the legacy ASLR mitigations.

### Legacy Mitigations (Fallback Mode)
When the proxy is not available, these workarounds reduce crash probability:
1. **ASLR Mitigation**: `Set-ProcessMitigation` disables high-entropy ASLR for `MATLAB.exe`.
2. **Timer Resolution**: System timer kept at ~15 ms during acquisition (not 1 ms) to reduce timer callback race probability by ~15x.
3. **Struct Alignment**: `ITCChannelInfo` corrected from `Pack=1` (104 bytes) to default alignment (112 bytes).
4. **Thread Safety**: All ITC hardware calls serialized through `_itcLock`.

---

## 6. NI-DAQ Controller Improvements

### Async Read/Write Fix
- Fixed buffer overflow errors (`-200292: samples could not be written to the buffer`) during digital output by writing analog data before digital data sequentially, rather than in parallel.
- The analog output provides the sample clock that drives digital output timing — writing digital data before the clock starts caused the digital output buffer to overflow.

### Chunked Write with Retry
- Both analog and digital write operations include retry logic with configurable delay for buffer-full conditions.
- Write operations attempt bulk writes first, falling back to chunked writes with retry if the buffer is full.

### Multi-Device Support
- The `MultiDeviceNIHardwareDevice` class supports multiple NI-DAQ devices on a single rig configuration.
- Useful for setups that need more analog inputs/outputs than a single NI-DAQ board provides.
- Device-specific tasks (AI, AO, DI, DO) are managed per-device with coordinated timing via master/slave clock configuration.

---

## 7. Cross-Platform Support

### macOS Compatibility
- Symphony 3 runs on macOS (Apple Silicon and Intel) for non-hardware simulations and file interaction.
- .NET assemblies are built for both `net48` (Windows) and `net10.0` (macOS/Linux) via separate solution files (`symphony-core-mac.slnx`).
- The `addAppPaths.m` script auto-detects the platform and loads assemblies from the appropriate directory:
  - Windows: `code/core/win_x64`
  - macOS ARM64: `code/core/osx-arm64`
  - macOS Intel: `code/core/osx-x64`
- Cross-platform .NET type resolution via `createNetObj()` and `callNetStatic()` helpers that use `System.Activator.CreateInstance` as a fallback when MATLAB's direct namespace resolution fails on macOS.
- `log4net` initialization failures on macOS (where `System.Configuration` is unsupported) are handled gracefully with a no-op logger fallback.

### Linux (Untested)
- The architecture supports Linux (`code/core/linux-x64`) but has not been tested.
- Once Stage server support is available on macOS/Linux, full simulation capabilities will be possible without Windows.

---

## 8. Protocol Presets — Export & Import

### Shareable Presets
- Protocol presets can be exported to `.mat` files and imported on other machines.
- **Export**: Select specific presets from a checklist dialog, save to the default data location.
- **Import**: Browse for a `.mat` preset file, select which presets to import, with conflict resolution (Overwrite, Skip, Cancel) for duplicates.
- Enables standardization of protocol parameters across rigs and labs.

### Preset Dialog Enhancements
- Double-click a preset to apply it.
- **View Only** and **Record** buttons on each preset for quick execution.
- Record button is grayed out when no epoch group is open.
- Protocol name shown in parentheses next to each preset name.

---

## 9. UI Modernization

### UIFigure Migration
- The main SymphonyApp UI uses MATLAB's modern `uifigure` framework (replacing the deprecated Java-based Swing components from Symphony 2).
- All dialogs (Initialize Rig, New File, Begin Epoch Group, Add Source, Options, Protocol Presets, Devices, Preview) are rebuilt as `uifigure`-based modal or non-modal windows.
- The Data Manager uses a custom `Splitter` component for resizable panels.

### UIFigure Edit Field Workaround
- In UIFigure, `KeyPressFcn` fires **before** `uieditfield` commits typed text to `.Value`. Pressing Enter in a dialog's text field would read the stale (pre-edit) value.
- Fixed via `ValueChangingFcn` which captures every keystroke into a `typedLabel` property. The dialog reads this captured text instead of `.Value`, ensuring the user's typed text is always used.
- `DialogUtil.setKeyPressFcnRecursive` propagates Enter/Escape handling to all child controls (dropdowns, checkboxes, etc.) so keyboard shortcuts work regardless of which control has focus.

### Figure Handlers — Traditional Figures
- Figure handler windows (Response, MeanResponse, ResponseStatistics, Progress, etc.) use traditional Java-backed `figure()` for maximum rendering performance.
- This provides 5–10x faster plot updates compared to `uifigure`-based rendering.

### Performance Optimizations
- Data Manager tree uses incremental updates after recording (0.04s vs 5.3s for full rebuild).
- Pre-grouped epoch blocks eliminate O(n^2) tree population.
- Lazy epoch loading — epochs are fetched on-demand when a block is selected, not when the file opens or after each acquisition. Files with 800+ epochs open instantly.
- Merge, Split, and Delete operations trigger a full tree rebuild (incremental updates can't handle structural changes).
- Protocol property grid uses individual `uieditfield`/`uidropdown` controls per property instead of a `uitable`, enabling device dropdowns and boolean toggles.
- View position persistence via MATLAB preferences for all dialogs and figure handlers.

### Rig Switching
- Switching rigs via Configure > Initialize Rig properly closes the old rig before opening the new one. This releases the MultiClamp Commander COM telegraph handle so the new rig can detect it.
- Figure handlers are closed on rig switch so they are recreated with fresh device references on the next protocol run.
- `MultiClampDevice` detection retries up to 5 times (500ms apart) to handle brief windows where Commander is not visible after rig close.

---

## 10. Source & Epoch Group Description System

### Hierarchical Source Management
- Source types (Subject, Preparation, Cell) are discovered from search paths and filtered by hierarchy level.
- Adding a child source from a right-click context menu automatically restricts the dropdown to valid child types for that parent.
- Source description properties (with dropdowns, multi-select checkboxes, and hierarchical tree selectors) are editable in the Data Manager.

### Epoch Group Descriptions
- Epoch group properties (e.g., external solution additions, recording technique, pipette solution) are populated from description classes and persisted to HDF5.
- **Carry Forward**: Properties from the previous epoch group are automatically carried forward to new epoch groups.

### Experiment Descriptions
- Experiment-level properties (experimenter, project, institution, lab, rig) are populated from experiment description classes.
- Properties with enumerated domains render as dropdowns.

---

## 11. Configuration & Options

### Startup & Cleanup Scripts
- **Startup File**: Runs automatically when SymphonyApp launches (e.g., adding custom paths, setting defaults).
- **Cleanup File**: Runs when SymphonyApp closes (e.g., removing paths, closing connections).
- **File Cleanup Function**: Runs after each data file is closed (e.g., post-processing).

### View Only Warning
- Configurable warning before running View Only with an open file, with a "don't show again" option per session.

### Dynamic File Naming
- Default file names support MATLAB expressions (e.g., `@()[datestr(now,'yyyymmdd') 'T']`).
- MATLAB numeric expressions can be entered in protocol property fields (e.g., `60*9*1000+59000`).

---

## 12. Module System

- Modules (e.g., Background Control) are discovered from search paths and loaded dynamically.
- The Background Control module has been rewritten for UIFigure compatibility, displaying device backgrounds with editable values.

---

## 13. Build & Deployment

### Consolidated Assembly Directory
- `copy_assemblies.bat` copies all required DLLs to a single directory (`code/core/win_x64` or `osx-arm64`).
- Includes `HekaITCProxy.exe` (32-bit) for Heka hardware isolation and `SymphonyH5Writer.exe` for out-of-process HDF5.
- Supports Windows, macOS ARM64, and macOS Intel builds:
  ```cmd
  copy_assemblies.bat              REM Windows
  copy_assemblies.bat Release mac  REM macOS ARM64
  ```

### Symphony.bat Launcher
- Portable launcher script using relative paths (`%~dp0`) — works regardless of installation directory.

### Backup Script
- `backup_symphony.bat` creates timestamped backups of the MATLAB and C# codebases, excluding build artifacts, `.vs`, and `.h5` files.

---

## 14. Improved Error Handling & Messaging

### The Problem in Symphony 2

Symphony 2's error reporting from the C# acquisition pipeline was largely opaque. When a .NET exception occurred during acquisition (e.g., a DAQ hardware error, HDF5 write failure, or device communication problem), the error was processed through a chain that frequently lost the original error message:

```matlab
% Symphony 2 — Controller.m error handling
if task.IsFaulted
    report = symphonyui.core.util.netReport(task.Exception.Flatten());
    isjson = ~isempty(regexp(report, '^\s*(?:\[.+\])|(?:\{.+\})\s*$', 'once'));
    if isjson
        ex = loadjson(report);
        ex.stack = cell2mat(ex.stack{1})';
        rethrow(ex);
    else
        error(report);
    end
end
```

This code attempted to:
1. Extract the innermost .NET exception message via `netReport()` (which walks `InnerException` until it reaches the root cause)
2. Check if the message is JSON (from `savejson`-serialized MATLAB exceptions that were caught in .NET callbacks)
3. Deserialize the JSON and rethrow as a MATLAB exception

**The failure modes:**

- **`netReport()` failures**: The `netReport` utility wraps the .NET exception in a `NET.NetException`, then walks `InnerException`. If the exception hierarchy is complex (e.g., `AggregateException` → `SymphonyControllerException` → `DaqException`), the innermost message was often a generic .NET message like `"One or more errors occurred"` rather than the actual hardware error.

- **JSON parsing failures**: When a MATLAB callback threw an error inside a .NET event handler, the error was serialized via `savejson`. The `loadjson` deserialization frequently failed due to special characters, nested structures, or version mismatches between `savejson`/`loadjson`. When JSON parsing failed, the user saw a generic `MException` with no useful information.

- **Lost stack traces**: The `rethrow(ex)` call with a deserialized JSON struct often produced stack traces pointing to the JSON deserialization code rather than the actual error location.

- **Silent suppression**: Errors in `.NET` event callbacks (like `CompletedEpoch`) were serialized to JSON via `savejson`, but if `savejson` itself threw (which happened with complex MATLAB objects), the original error was completely lost.

The net result: users frequently saw unhelpful error messages like `"MsException"` or `"One or more errors occurred"` with no indication of what actually went wrong.

### Symphony 3 Improvements

#### Full .NET Exception Logging

Before attempting JSON deserialization, the complete .NET exception (including all inner exceptions and stack traces) is dumped to both the MATLAB console and a persistent debug log:

```matlab
% Symphony 3 — Controller.m error handling
if task.IsFaulted
    fullReport = char(task.Exception.Flatten().ToString());
    fprintf(2, '\n=== .NET Task Exception ===\n%s\n===========================\n\n', fullReport);
    % Also write to streaming_debug.log for post-mortem analysis
    fid = fopen(fullfile(getenv('USERPROFILE'), 'streaming_debug.log'), 'a');
    fprintf(fid, '%s | MATLAB task.IsFaulted | %s\n', datestr(now), fullReport);
    fclose(fid);
    ...
end
```

The `task.Exception.Flatten().ToString()` call produces the complete .NET exception chain with all inner exceptions, source locations, and stack traces — the same output you would see in a C# debugger.

#### Robust JSON Fallback

The JSON deserialization path is now wrapped in additional try/catch blocks with fallback to the full .NET report:

```matlab
try
    report = symphonyui.core.util.netReport(task.Exception.Flatten());
catch
    report = fullReport;  % Fall back to complete .NET ToString()
    if isempty(report)
        report = 'Unknown .NET task fault';
    end
end
```

If `netReport` fails, the raw `.ToString()` output is used. If JSON parsing fails, the error is reported with a proper identifier (`symphonyui:controller:taskFaulted`) rather than a generic `MException`.

#### SymphonyApp Error Display

The `showError` method in `SymphonyApp.m` accepts both string messages and full `MException` objects. When given an exception, it dumps the complete stack trace (including causes) to the MATLAB command window via `fprintf(2, ...)` before showing the UI alert:

```matlab
function showError(app, msgOrException, title)
    if isa(msgOrException, 'MException')
        ex = msgOrException;
        fprintf(2, '\n=== %s ===\n', title);
        fprintf(2, '%s: %s\n', ex.identifier, ex.message);
        for k = 1:numel(ex.stack)
            fprintf(2, '  in %s (line %d)\n', ex.stack(k).name, ex.stack(k).line);
        end
        % Walk the cause chain
        cause = ex;
        while ~isempty(cause.cause)
            cause = cause.cause{1};
            fprintf(2, 'Caused by: %s\n', cause.message);
        end
    end
    uialert(app.UIFigure, char(msg), title);
end
```

#### Non-Fatal Figure Handler Errors

Errors from figure handlers during `CompletedEpoch` callbacks no longer crash the acquisition. They are logged as warnings and acquisition continues:

```matlab
catch ex
    fprintf(2, 'WARNING: CompletedEpoch callback error (acquisition continues): %s\n', ex.message);
end
```

This prevents a plotting error (e.g., index out of bounds from a data size mismatch) from terminating an entire recording session.

#### Persistent Debug Log

All .NET exceptions, HDF5 errors, and acquisition faults are appended to `~/streaming_debug.log` with timestamps. This provides a complete post-mortem record even if the MATLAB command window output was lost or the session crashed.
