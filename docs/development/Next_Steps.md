# Next Steps for the Data Acquisition Pipeline

## Immediate — Validate Recent Changes on Hardware

1. **Module preloading** — Verify the timer-based preloader works after rig init on both machines. Confirm modules open instantly on the slower R2024b machine. Watch for errors in the command window from modules that fail `willGo()` (e.g., LightCrafterControl when no LightCrafter is in the rig).

2. **LightCrafter mode switching** — Test pattern->video->pattern cycling on actual hardware. Confirm gamma ramps apply in video mode, PatternCompositor is skipped, and pattern rates repopulate correctly when switching back.

3. **E2E test checklist** — Run the full checklist at `SymphonyApp/docs/E2E_Test_Checklist.md` covering Heka, NI-DAQ, streaming, partial save, rig switching, and backward compatibility. Several items (Data Manager live updates during acquisition, 800+ epoch groups, partial save at 20 kHz) only break on real hardware.

## Short-Term — Stability & Data Integrity

4. **Streaming writes to the live file** — `Controller.cs` line 855 has a TODO: the `StreamingH5EpochWriter` writes incremental data directly into the target HDF5 file. If MATLAB crashes mid-epoch, the file could be left in an inconsistent state. Writing to a temp file and renaming on completion would add crash recovery for streaming epochs.

5. **MultiClamp duration validation** — `MulticlampDevice.cs` line 770: no check for stimulus duration shorter than one sample at the device's sample rate. This could produce a zero-length output buffer and undefined hardware behavior.

## Medium-Term — Performance & Polish

6. **Data Manager lazy property loading** — The tree builds fast now (lazy epoch loading), but entity properties are still fetched eagerly. Loading them on-demand when a node is selected would reduce memory and startup time for large files.

7. **Enable the out-of-process HDF5 writer as an option** — The infrastructure is fully built (`SymphonyH5Writer.exe`, named pipes). It's currently disabled because the batch save queue + separate `hdf5_symphony.dll` resolved the crash. For users who experience edge-case HDF5 contention, exposing `setpref('SymphonyUI', 'outOfProcessWriter', true)` as an Options dialog toggle would be a low-effort safety net.

8. **Clean up debug output** — There are `fprintf(2, ...)` debug statements scattered through the acquisition pipeline. A pass to route these through `log4m` (which is already in the codebase) would give users clean command window output while preserving diagnostics in `streaming_debug.log`.

## Longer-Term — Architecture

9. **Full out-of-process acquisition** (`SymphonyAcquisition.exe`) — Move the entire Controller + DAQController + Persistor into a separate process, giving complete fault isolation and enabling headless recording. The infrastructure patterns from the ITC proxy and HDF5 writer (named pipes, process lifecycle) are directly reusable. Highest-impact architectural change remaining but also the highest effort. See `Big_picture_priorities.md` Approach #5.

10. **Linux validation** — The `code/core/linux-x64` architecture exists in the build script and the .NET 10 targets compile for it, but it's untested. Mainly needs NI-DAQ driver availability (or simulation-only mode) and testing of the HDF5 P/Invoke paths.

11. **NI-DAQmx .NET retargeting** — National Instruments hasn't updated their .NET API yet. When they do, retargeting the Windows assemblies from `net48` to modern .NET would unify the Windows and cross-platform builds and drop the .NET Framework 4.8 dependency.
