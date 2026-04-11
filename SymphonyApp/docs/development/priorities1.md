

Out of process writer:

Here's a systematic stress test plan, ordered from least to most demanding:

### Test 1: Rapid Short Epochs (HDF5 Write Throughput)
- Protocol: `LedPulse`
- Settings: `preTime=10, stimTime=100, tailTime=100, numberOfAverages=100`
- Sample rate: 10 kHz
- **What it tests**: Many rapid HDF5 writes in quick succession. The batch queue should accumulate several epochs and flush them together.
- **Pass criteria**: All 100 epochs saved, no errors, Data Manager shows all epochs after recording

### Test 2: Long Epochs (Memory & Streaming)
- Protocol: `LedPulse`
- Settings: `preTime=500, stimTime=60000, tailTime=500, numberOfAverages=3`
- Streaming: ON, threshold=5s
- **What it tests**: Large data volumes (600K samples per epoch at 10kHz), streaming ring buffer, `_fullData` accumulation, `DisableStreaming` + batch save
- **Pass criteria**: All 3 epochs saved with full data, MeanResponseFigure shows correct average, no memory runaway

### Test 3: High Sample Rate (Data Pipeline Speed)
- Protocol: `LedPulse`
- Settings: `preTime=10, stimTime=500, tailTime=100, numberOfAverages=20`
- Sample rate: 50 kHz
- **What it tests**: High-throughput data flow, `GetDataArray` performance, figure update speed
- **Pass criteria**: Figures update without freezing, all epochs saved correctly

### Test 4: Repeated Start/Stop Cycles (Handle Leaks)
- Run 5 epochs, stop, change a parameter, run 5 more, stop, repeat 10 times
- **What it tests**: HDF5 handle leaks, epoch block creation/closure, figure handler lifecycle
- **Pass criteria**: UI remains responsive after all cycles, no progressive slowdown, memory stays stable

### Test 5: Multiple Epoch Groups (Data Manager Stress)
- Create 5 epoch groups, record 10 epochs each, end each group
- **What it tests**: Tree rebuild performance, epoch group carry-forward, HDF5 group creation
- **Pass criteria**: Begin/End epoch group stays fast (<0.5s), tree populates correctly

### Test 6: Early Stop with Partial Save (if streaming enabled)
- Long epoch (60s), stop at ~30s, choose "Save Partial"
- Then record another full epoch group
- **What it tests**: Partial save, epoch queue flushing, recovery after stop
- **Pass criteria**: Partial epoch saved with correct sample count, next recording works normally

### Test 7: Extended Duration (Stability Soak)
- Record continuously for 30+ minutes with 5-second epochs
- **What it tests**: Memory leaks, handle accumulation, progressive slowdown, HDF5 file growth
- **Pass criteria**: UI remains responsive, figure handlers don't slow down, no crashes

### Test 8: File Compatibility
- After each test, close the file and reopen it in:
  1. Symphony 3 Data Manager (verify tree, epoch data, properties)
  2. Symphony 2 (if available — verify backward compatibility)
  3. MATLAB `h5info`/`h5read` (verify raw HDF5 structure)

### Monitoring During Tests

Watch for these in the console:
```
WARNING: ...           ← any warnings
[Controller] ...       ← batch save messages
H5O.open failed ...    ← HDF5 handle issues
```

And check system resources:
```matlab
% Run periodically to check memory
[~, mem] = system('tasklist /fi "imagename eq MATLAB.exe" /fo csv');
disp(mem)
```

### On the Target Machine (Crash-Prone)

If testing on the machine that had `abort()` crashes:
- Run Test 1 and Test 5 first — these involve the most HDF5 writes
- Monitor for any crash dumps in `%TEMP%\matlab_crash_dump.*`
- Check `streaming_debug.log` for any errors

Start with Test 1 and work through the list. Let me know the results and I'll help address any issues that surface.


Now to enable it, run this in MATLAB (one time — it persists):

```matlab
setpref('SymphonyUI', 'outOfProcessWriter', true);
```

Then restart Symphony. To disable later:

```matlab
setpref('SymphonyUI', 'outOfProcessWriter', false);
```

No C# rebuild needed.

Disable the out-of-process writer for now and rely on the batch save queue + Data Manager pause (which passed all tests)
Continue debugging the handoff — but this requires routing ~10 more persistor methods through the pipe
Redesign the approach — have the writer process own a complete copy of the Controller + DAQ pipeline (full out-of-process acquisition)
My recommendation: go with Option 1 for stability. The batch save queue already eliminated most contention. The out-of-process writer can be revisited as a future enhancement with a cleaner architectural boundary.

What would be the next steps if we went backward and chose (1)?



With Option 1 (batch save queue + Data Manager pause), the remaining work to further improve stability and performance:

Immediate (Low Effort)
Disable the out-of-process writer by default — Set UseOutOfProcessWriter = false, keep the infrastructure in place for future use
Clean up debug output — Remove remaining fprintf debug lines we haven't cleaned yet
Test on the target machine — The batch save queue changes haven't been tested on the crash-prone machine yet
Short Term (Medium Effort)
Tighten the batch save timing — Currently epochs are flushed during inter-epoch intervals AND at the end of acquisition. We could add a minimum delay (e.g., 100ms) after the last MATLAB drawnow before flushing, to ensure MATLAB's HDF5 is idle

Add a "safe flush" mechanism — Before flushing the epoch queue, set a flag that MATLAB checks in all HDF5-reading code paths. This creates a guaranteed window where only our C# code touches HDF5:

MATLAB: set safeToWrite flag → pause(0.1) → clear flag
C#:     wait for safeToWrite → flush queue → signal done

Data Manager refresh throttle — Add a minimum interval between refreshes (e.g., 500ms) so rapid state changes don't trigger multiple HDF5 reads

Reduce HDF5 operations per epoch — Profile which HDF5 calls are slowest and optimize (e.g., batch attribute writes, reduce group traversals)

Medium Term (Higher Effort)
Lazy property reads in Data Manager — Don't read entity properties until the user clicks on a specific entity (currently GetDataManagerStateAsync reads everything)

HDF5 file format optimization — Pre-allocate dataset space for known epoch lengths to reduce HDF5 metadata overhead

Separate HDF5 library — Build HDF5 from source with a unique library name (hdf5_symphony.dll) to completely isolate from MATLAB's copy. This eliminates the root cause without the process boundary complexity