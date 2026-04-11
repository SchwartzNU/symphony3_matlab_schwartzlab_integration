# Streaming Mode

Streaming mode reduces memory usage during long epochs by writing response data to HDF5 in real time and keeping only a sliding window of recent data in RAM. This is essential for multi-minute recordings where holding the entire epoch in memory would exhaust available RAM.

---

## Quick Start

1. **Enable:** Configure > Options > Streaming > check **Enable Streaming Mode**
2. **Set threshold:** Default is 5 seconds. Epochs shorter than this run normally (all data in RAM). Epochs longer switch to ring-buffer mode automatically.
3. **Record:** Run your protocol. Long epochs stream to disk transparently. Figure handlers show a sliding window of recent data.
4. **Early stop:** Click **Stop** during a long epoch. Symphony offers to save the partial data collected so far.

No protocol code changes are required. Streaming is fully automatic once enabled.

---

## Configuration

All streaming settings are in **Configure > Options > Streaming**.

| Setting | Default | Description |
|---------|---------|-------------|
| **Enable Streaming Mode** | Off | Master switch. When off, all data stays in RAM (original behavior). |
| **Threshold (seconds)** | 5 | Epoch duration before ring-buffer mode activates. Each device's response independently switches to streaming when its duration exceeds this value. |
| **Display Chunks** | 10 | Number of data chunks (~250 ms each) kept in the ring buffer. Controls how much recent data figure handlers can display. At default settings: ~2.5 seconds of data visible. |

### Programmatic Configuration

```matlab
opts = symphonyui.app.Options.getDefault();
opts.streamingEnabled = true;
opts.streamingThreshold = 3;          % seconds
opts.streamingMaxDisplayChunks = 20;  % ~5 seconds visible
opts.save();
```

---

## How It Works

### Data Flow During a Streaming Epoch

```
Hardware → DAQ Controller → ProcessLoop → PushInputData
                                              │
                              ┌────────────────┼────────────────┐
                              │                │                │
                         Response          Streaming       Background
                         Ring Buffer       Write Queue     Flush Thread
                         (in RAM)          (ConcurrentQueue)    │
                              │                │                │
                              │                └──► AppendResponseData
                              │                     (HDF5 dataset extend)
                              │                         │
                         Figure Handlers           Flush to disk
                         (sliding window)          (~every 1 second)
```

1. **Normal phase** (epoch duration < threshold): All response data accumulates in `Response._orderedData`. No HDF5 writes until epoch completes.

2. **Streaming activates** (duration exceeds threshold):
   - `Response.IsStreaming` becomes `true`
   - Data is added to both `_orderedData` (ring buffer) and `_fullData` (complete accumulator)
   - When `_orderedData` exceeds `MaxDisplayChunks`, the oldest chunk is evicted from RAM
   - `_fullData` keeps everything for final HDF5 serialization

3. **Background HDF5 writes**: `PushInputData` enqueues data chunks to a `ConcurrentQueue`. A background thread drains the queue and writes to HDF5 using extendable, chunked datasets. This runs off the ProcessLoop thread so hardware servicing is never delayed.

4. **Epoch completes**: `FinalizeEpoch` writes end time and metadata. `DisableStreaming` restores full data into `_orderedData` for the standard epoch serialization path. The epoch is also saved to the normal HDF5 location via `FlushEpochSaveQueue`.

5. **Early stop (partial save)**: The user can stop mid-epoch. The incomplete epoch is marked with `IsPartial = true` and serialized with whatever data has been collected.

### Ring Buffer Details

Each chunk is approximately one `ProcessInterval` (~250 ms) of data. At 10 kHz sample rate:

| Display Chunks | Window Duration | Samples in RAM | RAM Usage (per device) |
|----------------|-----------------|----------------|----------------------|
| 5 | ~1.25 s | ~12,500 | ~100 KB |
| 10 (default) | ~2.5 s | ~25,000 | ~200 KB |
| 20 | ~5.0 s | ~50,000 | ~400 KB |

Without streaming, a 60-second epoch at 10 kHz holds 600,000 samples (~4.8 MB) per device in RAM. With streaming enabled, RAM usage is capped at the ring buffer size regardless of epoch duration.

---

## Hardware Compatibility

### NI-DAQ: Full Streaming Support

NI-DAQ hardware uses DMA (Direct Memory Access) buffers that tolerate brief delays in the acquisition loop. Streaming works at all sample rates (10 kHz, 20 kHz, 50 kHz).

### Heka ITC-18: Full Streaming Support (with ITC Proxy)

Streaming is fully supported on Heka hardware when the **32-bit ITC proxy** (`HekaITCProxy.exe`) is running. The proxy isolates ITCMM.dll in a separate process, so HDF5 streaming writes in the MATLAB process cannot block the hardware's ProcessLoop.

**How to verify the proxy is running:**
```matlab
system('tasklist /fi "imagename eq HekaITCProxy.exe" /fo list')
```

The MATLAB command window shows `[HekaDAQController] Using ITC proxy process (32-bit)` when the proxy is active.

**Without the proxy (fallback mode):** If `HekaITCProxy.exe` is not found, ITCMM.dll loads in-process. In this mode, streaming HDF5 writes can cause `Hdf5Lock` contention that delays the ITC FIFO servicing, particularly at high sample rates (20 kHz+). If FIFO overflow errors occur in fallback mode, consider disabling streaming in Options or using the NI-DAQ rig.

For details on the ITC proxy architecture, see [ITC_Driver_Bug.md](ITC_Driver_Bug.md#definitive-fix-32-bit-itc-proxy-process).

---

## Figure Handlers and Streaming

### Automatic Behavior

Figure handlers that set `requiresFullEpoch = false` receive live updates during streaming epochs. The base class provides an `isStreamingActive()` helper method.

### Built-in Figure Handler Behavior

| Figure Handler | Streaming Support | Behavior |
|----------------|-------------------|----------|
| **ResponseFigure** | Yes (`requiresFullEpoch = false`) | Shows sliding window of recent data. Title displays "(streaming)" during acquisition. |
| **MeanResponseFigure** | Yes (`requiresFullEpoch = false`) | Shows semi-transparent preview line during streaming. On epoch completion, uses `getFullData()` to compute the proper running average from all samples. |
| **ResponseStatisticsFigure** | Yes | Uses `getFullData()` with bounds checking. Gracefully handles partial data. |
| **ProgressFigure** | N/A | Tracks epoch count, not affected by streaming. |

### Writing a Streaming-Aware Figure Handler

The key pattern: use `epoch.isComplete()` to distinguish streaming updates from completion callbacks. `DisableStreaming()` is called before the `CompletedEpoch` event fires, so `getData()` returns full data in the completion callback.

```matlab
classdef MyStreamingFigure < symphonyui.core.FigureHandler

    methods
        function obj = MyStreamingFigure(device)
            obj.device = device;
            obj.requiresFullEpoch = false;  % Receive streaming updates
        end

        function handleEpoch(obj, epoch)
            if ~epoch.hasResponse(obj.device)
                return;
            end
            response = epoch.getResponse(obj.device);

            if ~epoch.isComplete()
                % INCOMPLETE EPOCH (streaming update or pre-threshold):
                % Show preview only — do NOT update running statistics.
                [quantities, units] = response.getData();

                if response.isStreaming()
                    % Streaming active: show sliding window at correct position
                    totalSamples = response.getTotalSampleCount();
                    startSample = totalSamples - numel(quantities) + 1;
                    x = (startSample:totalSamples) / sampleRate;
                else
                    % Pre-threshold: show all data from the beginning
                    x = (1:numel(quantities)) / sampleRate;
                end
                % Draw preview line...
                return;
            end

            % COMPLETED EPOCH: update running mean/statistics with full data.
            % DisableStreaming() was called before CompletedEpoch fired,
            % so getData() and getFullData() both return ALL samples.
            [quantities, units] = response.getFullData();
            % Compute final analysis, update running mean, etc.
        end
    end
end
```

**Important:** Do not use `response.isStreaming()` as the sole guard for the preview path. Before the streaming threshold is exceeded, `isStreaming()` is `false` but the epoch is still incomplete. Using `epoch.isComplete()` correctly handles both pre-threshold and active streaming epochs.

### Key API Methods

| Method | Returns | When to Use |
|--------|---------|-------------|
| `epoch.isComplete()` | `true`/`false` | Distinguish streaming updates from completion callbacks |
| `response.getData()` | Ring buffer window during streaming; full data after completion | Live display or final data |
| `response.getFullData()` | All samples (entire epoch) | Final analysis after epoch completes |
| `response.isStreaming()` | `true`/`false` | Check if response is in ring-buffer mode (for time axis calculation) |
| `response.getTotalSampleCount()` | Total samples received | Calculate correct time axis during streaming |
| `handler.isStreamingActive()` | `true`/`false` | Helper to check if any device is streaming |

---

## Partial Epoch Save

When a long epoch is stopped early, Symphony offers to save the data collected so far.

### User Workflow

1. During a recording epoch, click **Stop**
2. If data has been collected, a dialog appears: **Save partial data? / Discard / Cancel**
3. **Save**: The epoch is marked as partial (`IsPartial = true`) and written to HDF5 with all data collected up to the stop point
4. **Discard**: The incomplete epoch is thrown away
5. **Cancel**: Acquisition continues

### Identifying Partial Epochs

In the Data Manager, partial epochs appear like normal epochs. To check programmatically:

```matlab
% After opening a file and navigating to an epoch
epoch = ...;  % persistent epoch from Data Manager
params = epoch.protocolParameters;
% Check the HDF5 attributes for IsPartial flag
```

### Technical Details

- The **first** incomplete data epoch (not an interval) is marked as partial. At high sample rates (20 kHz+), multiple epochs can be queued simultaneously — the code iterates from the first and marks the first one with response data.
- `DisableStreaming()` restores the full data from `_fullData` into `_orderedData`
- `Serialize()` writes the epoch to HDF5 under `Hdf5Lock` after the hardware stops
- The entire partial save path is exception-proof — if `DisableStreaming()`, `Serialize()`, or event callbacks fail, errors are logged to `streaming_debug.log` but MATLAB does not crash
- If serialization fails, the error is logged to `streaming_debug.log` but MATLAB does not crash

---

## HDF5 File Layout

### Standard Epoch Save (Non-Streaming)

Epochs are serialized by `H5EpochPersistor.Serialize()` into the standard hierarchy:

```
/experiment-{uuid}/
  epochGroups/epochGroup-{uuid}/
    epochBlocks/epochBlock-{uuid}/
      epochs/epoch-{uuid}/
        responses/response-{uuid}/data    ← full double[] array
        stimuli/stimulus-{uuid}/data
        backgrounds/background-{uuid}/data
```

### Streaming Epoch Structure

The streaming writer creates a parallel structure under `/streaming/` for crash recovery:

```
/streaming/epoch-{uuid}/
  @protocolID: string
  @startTime: ISO 8601 string
  @endTime: ISO 8601 string         ← written at finalization
  @isPartial: bool                   ← true if stopped early
  @streamingVersion: 2
  @totalSamples_{DeviceName}: ulong  ← per-device sample count
  protocolParameters/                ← HDF5 attributes
  responses/
    {DeviceName}: double[N]          ← chunked, extendable dataset
      @sampleRate, @units, @inputTime
  stimuli/{DeviceName}               ← pre-written at epoch start
  backgrounds/{DeviceName}
```

When the epoch completes normally, data is also written to the standard location by the epoch save queue. The `/streaming/` data serves as a backup for crash recovery.

### Dataset Properties

- **Chunk size:** ~10,000 samples (~1 second at 10 kHz)
- **Compression:** gzip level 1 (fast, ~2:1 ratio on typical electrophysiology data)
- **Extendable:** Datasets grow as data arrives, using HDF5 chunked storage

---

## Crash Recovery

If MATLAB crashes during a streaming epoch, the `/streaming/` HDF5 data survives on disk. Use `StreamingEpochReader` to recover:

```matlab
reader = symphonyui.core.StreamingEpochReader(filepath);

% List all streaming epochs
paths = reader.getEpochPaths();

% Read info about a specific epoch
info = reader.readEpochInfo(paths{1});
fprintf('Protocol: %s, Partial: %d\n', info.protocolID, info.isPartial);

% Read response data
resp = reader.readResponse(paths{1}, 'Amp1');
fprintf('Samples: %d, Rate: %.0f Hz\n', numel(resp.values), resp.sampleRate);

% Recover all unfinalized epochs (mark as partial, write end times)
symphonyui.core.StreamingEpochReader.recoverCrashedEpochs(filepath);
```

---

## Troubleshooting

### "Controller: streaming auto-disabled for Heka hardware"

Expected behavior. Streaming is not compatible with Heka ITC hardware. All data stays in memory. See [Hardware Compatibility](#hardware-compatibility).

### Epochs appear shorter than expected

Check that `streamingThreshold` is set lower than your epoch duration. Epochs shorter than the threshold run entirely in RAM without streaming.

### Figure handlers show no data during streaming

Ensure `requiresFullEpoch = false` is set in your figure handler constructor. The default (`true`) suppresses updates until the epoch completes.

### High memory usage despite streaming

- Check that streaming is actually enabled: `symphonyui.app.Options.getDefault().streamingEnabled`
- Verify the threshold: epochs shorter than the threshold don't stream
- If using Heka hardware, streaming is auto-disabled — all data stays in RAM

### "ITC not running" errors on Heka

This occurs when the ProcessLoop is blocked. Streaming is now auto-disabled for Heka, but if you see this on short epochs, check for other sources of blocking (figure handler computation, disk I/O, etc.).

### Partial save fails silently

Check `streaming_debug.log` in your user profile directory for error details:
```matlab
edit(fullfile(getenv('USERPROFILE'), 'streaming_debug.log'))
```

---

## Performance Characteristics

| Operation | Typical Time | Notes |
|-----------|-------------|-------|
| `getData()` (ring buffer) | ~0.007 s (100k samples) | Fast C# `GetDataArray()` path |
| `getFullData()` | ~0.008 s (100k samples) | Similar to `getData()` |
| Streaming flush | ~0.050 s | Background thread, no acquisition impact |
| Epoch save (60s at 10 kHz) | ~0.200 s | Background thread via `FlushEpochSaveQueue` |
| File creation | ~0.015 s | One-time cost |

Measured on representative hardware. See `symphonyui.ui.profileAcquisition()` for machine-specific benchmarks.
