# Symphony Options

The Options dialog (**Configure > Options**) controls application-wide settings that persist across sessions using MATLAB's preference system (`setpref`/`getpref`). Settings are managed through `symphonyui.app.Options`, which extends `appbox.Settings`.

---

## General Tab

### Startup File

A MATLAB script or function that runs automatically when SymphonyApp launches, after core initialization (host, controller, protocol/module population) but **before** the Initialize Rig dialog appears.

**Use cases:**
- Adding custom paths to the MATLAB search path
- Setting default options programmatically
- Loading calibration data or instrument configurations
- Pre-configuring the environment for a specific lab setup

**Accepted values:**
- A path to a `.m` script file (e.g., `C:\lab\symphony_startup.m`)
- A function handle string (e.g., `@()myStartupFunction()`)
- Empty string (no startup action)

**Example startup script:**
```matlab
% symphony_startup.m — runs once when SymphonyApp launches
addpath('C:\lab\protocols');
addpath('C:\lab\rigs');
addpath('C:\lab\calibration');
opts = symphonyui.app.Options.getDefault();
opts.searchPath = 'C:\lab\protocols;C:\lab\rigs';
opts.save();
disp('Lab environment configured.');
```

**Example startup function handle (inline):**
```
@()addpath('C:\lab\protocols')
```

Use the **Browse** button (`...`) to select a script file from the filesystem.

**Execution timing:** The startup file runs after the host, controller, and UI are initialized, but *before* the Initialize Rig dialog appears. This ensures custom paths and options are available when the rig list is populated.

### Cleanup File

A MATLAB script or function that runs automatically when SymphonyApp closes, **before** the acquisition host shuts down and the Data Manager is closed. This ensures the cleanup script can still access host resources if needed.

**Use cases:**
- Removing paths that were added during startup
- Closing external instrument connections
- Saving calibration state or session logs
- Resetting environment variables

**Accepted values:** Same as Startup File (script path, function handle string, or empty).

**Example cleanup script:**
```matlab
% symphony_cleanup.m — runs once when SymphonyApp closes
disp('Symphony shutting down...');
% Remove paths that were added during startup
rmpath('C:\lab\protocols');
rmpath('C:\lab\rigs');
% Close any open instrument connections
try
    fclose(instrfindall);
catch
end
disp('Cleanup complete.');
```

**Example cleanup function handle (inline):**
```
@()disp('Symphony closed.')
```

**Execution timing:** The cleanup file runs when the app window is closed, *before* the acquisition host shuts down and the Data Manager is destroyed. This allows the cleanup script to access host resources if needed.

### Warn on View Only with Open File

When checked, Symphony displays a confirmation dialog before running a protocol in **View Only** mode if a data file is currently open. This serves as a safety net to prevent accidentally running a protocol without recording data.

**Default:** Enabled (checked)

The warning reads: *"A file is currently open. Running in View Only mode will not save any data. Continue?"* with **Yes** and **No** buttons. Selecting **No** cancels the View Only action so you can switch to **Record** instead.

---

## File Tab

### Default Name

The default file name suggested in the **New File** dialog. Can be a static string or a MATLAB expression that generates a dynamic name.

**Examples:**
- Static: `experiment_001`
- Dynamic (date-based): `@()datestr(now, 'yyyymmdd')` generates `20260325`
- Dynamic with prefix: `@()[datestr(now, 'yyyymmdd') 'T']` generates `20260325T`

When a function handle is stored, it is evaluated each time the New File dialog opens, producing a fresh name.

### Default Location

The default directory where new data files (`.h5`) are saved. Can be a static path or a function handle that returns a path.

**Examples:**
- Static: `C:\data\symphony`
- Dynamic: `@()fullfile('C:\data', datestr(now, 'yyyy-mm'))` creates monthly subdirectories

Use the **Browse** button (`...`) to select a directory.

### Cleanup Function

A function handle that runs each time a data file is closed. It receives a single argument (currently `[]` in the new UI; was `documentationService` in the old UI) and can be used to perform post-processing on the closed file.

**Default:** `@(documentationService)[]` (no-op)

**Examples:**

Simple notification:
```matlab
@(ds)disp('File closed and cleaned up')
```

Post-process the most recently modified `.h5` file:
```matlab
@(ds)postprocess_latest('C:\data')
```

where `postprocess_latest.m` is:
```matlab
function postprocess_latest(dataDir)
    files = dir(fullfile(dataDir, '*.h5'));
    if ~isempty(files)
        [~, idx] = max([files.datenum]);
        latestFile = fullfile(files(idx).folder, files(idx).name);
        fprintf('Post-processing: %s\n', latestFile);
        % Add your custom analysis here
    end
end
```

**Common one-liners:**

| Cleanup Function | What It Does |
|---|---|
| `@(ds)[]` | No-op (default) |
| `@(ds)disp('Done!')` | Print a message |
| `@(ds)beep` | Play a beep sound |
| `@(ds)movefile(ds, 'C:\archive\')` | Move the file (if path is available) |

> **Note:** In the new UI, the cleanup function argument is `[]` (not the old `documentationService`). If you need the file path, find the most recently modified `.h5` in your data directory as shown above.

---

## Search Path Tab

### Search Paths

A list of directories that Symphony scans for discoverable classes. These directories should contain MATLAB package folders (`+packageName`) with subclasses of Symphony's core types:

| Package Convention | Discovered As | Base Class |
|---|---|---|
| `+protocols` | Protocols | `symphonyui.core.Protocol` |
| `+rigs` | Rig Descriptions | `symphonyui.core.descriptions.RigDescription` |
| `+sources` | Source Descriptions | `symphonyui.core.persistent.descriptions.SourceDescription` |
| `+epochgroups` | Epoch Group Descriptions | `symphonyui.core.persistent.descriptions.EpochGroupDescription` |
| `+experiments` | Experiment Descriptions | `symphonyui.core.persistent.descriptions.ExperimentDescription` |
| `+modules` | Modules | `symphonyui.ui.Module` |

**How it works:**
1. The scanner (`ui.ProtocolScanner`) recursively walks each search path directory
2. Inside each `+package` folder, it loads `.m` files via `meta.class.fromName`
3. It checks the superclass chain to determine if a class is a subclass of the target type
4. Abstract classes are skipped; only concrete classes appear in the UI

**Built-in paths:** The `SymphonyApp/code/src/resources/examples` directory is always included automatically.

Use **Add...** to browse for additional directories and **Remove** to delete selected entries. Paths are stored as a semicolon-delimited string in `symphonyui.app.Options.searchPath`.

### Exclude

A pattern string for excluding specific classes or packages from discovery. Classes whose fully-qualified names match this pattern are skipped during scanning.

---

## Logging Tab

### Configuration File

Path to an XML logging configuration file (e.g., `log4net` or `log4m` configuration). Controls log levels, output formats, and log destinations.

**Default:** The `log.xml` file in the built-in examples directory.

### Log Directory

Directory where Symphony writes log files during operation.

**Default:** `~/.symphony/logs` (user's home directory).

Use the **Browse** button (`...`) to select a different directory.

---

## Streaming Tab

Streaming mode reduces memory usage during long epochs by writing response data to HDF5 in real time and keeping only a sliding window of recent data in RAM. For full details, see [Streaming.md](Streaming.md).

> **Note:** Streaming is fully supported on Heka hardware when the 32-bit ITC proxy (`HekaITCProxy.exe`) is running. See [Streaming.md — Hardware Compatibility](Streaming.md#hardware-compatibility) for details.

### Enable Streaming Mode

When checked, epochs that exceed the threshold duration automatically switch to ring-buffer mode. Response data is streamed to HDF5 as it arrives (~250 ms chunks), and only the most recent chunks are kept in memory.

**Default:** Disabled (unchecked)

When streaming is disabled, all response data is held in RAM for the full epoch duration (original behavior).

### Threshold (seconds)

The epoch duration threshold before streaming activates. Epochs shorter than this value behave normally (all data in RAM). Epochs longer than this value switch to ring-buffer mode automatically.

**Default:** 5 seconds

**Guidelines:**
- 5 seconds is suitable for most protocols
- Shorter thresholds (1-2 seconds) are more memory-efficient but limit the data window available to figure handlers
- The threshold applies per-response: each device's response independently determines when to switch to streaming

### Display Chunks

The number of data chunks retained in the ring buffer. Each chunk is approximately 250 ms of data (one ProcessInterval). This controls how much recent data figure handlers can display.

**Default:** 10 chunks (~2.5 seconds of data)

**Effect on figure handlers:**
- `ResponseFigure` shows the most recent ~2.5 seconds of data as a sliding window
- `MeanResponseFigure` computes running averages over the available window
- Other figure handlers gracefully degrade — they display whatever data is available

---

## Settings Persistence

All options are stored via MATLAB's `setpref`/`getpref` system under the `symphonyui` group. Settings persist across MATLAB sessions and are specific to the current user account.

To reset all options to defaults:
```matlab
opts = symphonyui.app.Options.getDefault();
opts.reset();
opts.save();
```

To inspect current settings programmatically:
```matlab
opts = symphonyui.app.Options.getDefault();
disp(opts.searchPath);
disp(opts.startupFile);
disp(opts.fileDefaultName);
```
