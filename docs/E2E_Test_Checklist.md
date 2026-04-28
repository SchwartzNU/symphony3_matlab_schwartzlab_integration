# Symphony 3 — End-to-End Test Checklist

Manual verification steps for hardware-dependent testing. Run `symphonyui.ui.runEndToEndTests()` for automated tests first, then walk through this checklist on each rig.

---

## Prerequisites

- [ ] `addAppPaths()` completes without errors
- [ ] SymphonyApp launches (`SymphonyApp`)
- [ ] MATLAB version: R2024b or later (UIFigure support)

---

## Heka ITC-18 Rig

**Rig class:** `io.github.symphony_das.rigs.HekaDaqWithAxopatch`

### Initialization
- [ ] Configure > Initialize Rig — select HekaDaqWithAxopatch
- [ ] No ITCMM.dll crash or ASLR error
- [ ] No .NET assembly load errors in command window
- [ ] Rig devices appear (Amp1, Amp2, LEDs, Triggers)

### Basic Acquisition
- [ ] Select Pulse protocol, set numberOfAverages = 5
- [ ] **View Only** — ResponseFigure updates live each epoch
- [ ] **View Only** — MeanResponseFigure accumulates running average
- [ ] **View Only** — ResponseStatisticsFigure shows mean/var
- [ ] Stop completes cleanly, state returns to idle

### Recording
- [ ] Document > New File — creates .h5 file
- [ ] Document > Begin Epoch Group — dialog opens, select source and description
- [ ] **Record** Pulse (5 epochs) — data saved to file
- [ ] Data Manager tree shows: Epoch Group > Epoch Block > 5 Epochs
- [ ] Select an epoch in Data Manager — response waveform displays
- [ ] Document > End Epoch Group

### Multi-Epoch Protocol
- [ ] Select PulseFamily, pulsesInFamily=3, numberOfAverages=2 (6 total epochs)
- [ ] **Record** — all 6 epochs appear in Data Manager
- [ ] Verify `pulseSignal` parameter varies across pulses

### Pause / Resume / Stop
- [ ] Start recording Pulse (numberOfAverages=20)
- [ ] Click **Pause** mid-run — current epoch completes, acquisition pauses
- [ ] Click **Resume** — acquisition continues from where it left off
- [ ] Click **Stop After Epoch** — current epoch saves, then stops
- [ ] Start again, click **Stop** (immediate) — incomplete epoch discarded

### Streaming (Long Epoch)
- [ ] Configure > Options > Streaming — enable, threshold = 3s
- [ ] Select Pulse, set stimTime = 10000 (10s), numberOfAverages = 1
- [ ] **Record** — ResponseFigure shows sliding window during epoch
- [ ] Title shows "(streaming)" indicator
- [ ] After completion, verify epoch saved in Data Manager
- [ ] Verify RAM usage stays stable (check Task Manager)
- [ ] Disable streaming in Options when done

### Data Manager Live Updates
- [ ] Start a recording run (5+ epochs)
- [ ] While acquisition is running, observe Data Manager tree
- [ ] Tree should update with new epochs as they complete
- [ ] Selecting a completed epoch during acquisition shows its data

### Source Management
- [ ] Document > Add Source — dialog opens
- [ ] Add a Subject source with label
- [ ] Add a child source (Preparation) under the Subject
- [ ] Add a grandchild source (Cell) under the Preparation
- [ ] Verify hierarchy in Data Manager tree

---

## NI-DAQ Rig

**Rig class:** `io.github.symphony_das.rigs.NiDaqWithAxopatch`

### Initialization
- [ ] Configure > Initialize Rig — select NiDaqWithAxopatch
- [ ] No buffer overflow or NI driver errors
- [ ] Devices appear correctly (Amp1, Amp2, LEDs, Triggers)

### Basic Acquisition (repeat Heka section)
- [ ] View Only with Pulse — ResponseFigure updates live
- [ ] Record with Pulse — data saved correctly
- [ ] PulseFamily — correct number of epochs with varying parameters

### Pause / Resume / Stop (repeat Heka section)
- [ ] Pause / Resume works correctly
- [ ] Stop After Epoch saves cleanly
- [ ] Immediate Stop discards incomplete epoch

### Streaming (repeat Heka section)
- [ ] Long epoch with streaming enabled — sliding window display
- [ ] Data saved correctly after streaming epoch

### NI-Specific
- [ ] Digital output triggers fire (doport0)
- [ ] Analog output (ao0-ao3) produces correct waveforms
- [ ] Analog input (ai0-ai1) captures responses
- [ ] No `-200292` buffer overflow errors during normal operation
- [ ] Multi-device clock sync (if multiple NI boards present)

---

## Cross-Rig Compatibility

### File Compatibility
- [ ] Record data with Heka rig, close file
- [ ] Open same file with NI rig initialized — data reads correctly
- [ ] Record data with Symphony 3, open in **Symphony 2** — no errors
- [ ] Open a **Symphony 2** file in Symphony 3 — Data Manager loads correctly

### Backward Compatibility (PropertyDescriptor)
- [ ] Open a Symphony 3 file in Symphony 2
- [ ] No "Struct contents reference from a non-struct" errors
- [ ] Sources display with correct property descriptors
- [ ] Epoch group properties load correctly
- [ ] If errors occur on old files, run `symphonyui.ui.fixH5ForSymphony2(filepath)` then retry

### Options Dialog
- [ ] Configure > Options — all tabs visible (General, File, Search Path, Logging, Streaming)
- [ ] Modify a setting in each tab, click Save
- [ ] Reopen Options — verify settings persisted
- [ ] Close and relaunch SymphonyApp — settings still persisted

### Protocol Presets
- [ ] Select Pulse, modify parameters (e.g., pulseAmplitude = 200)
- [ ] Save as preset (e.g., "HighAmp")
- [ ] Change parameters, load preset — original values restored
- [ ] Export presets to .mat file
- [ ] Clear presets, import from .mat file — presets restored
- [ ] View Only with loaded preset — correct parameters used

### Rig Switching
- [ ] Initialize Heka rig, run a protocol
- [ ] Configure > Initialize Rig — switch to NI rig
- [ ] Run same protocol on NI rig — no stale state from Heka, figures recreated
- [ ] Switch back to Heka — MultiClamp Commander detected without error
- [ ] Verify `HekaITCProxy.exe` starts on Heka init (`tasklist /fi "imagename eq HekaITCProxy.exe"`)

### Dialog Label Entry
- [ ] Begin Epoch Group — type custom label, press Enter — verify label is saved (not default)
- [ ] Begin Epoch Group — select different description, verify label auto-populates
- [ ] Begin Epoch Group — type label, click Begin button — verify label is saved
- [ ] New File — type custom filename, press Enter — verify filename used

### Data Manager Operations
- [ ] Merge two adjacent epoch groups — verify blocks appear in merged group
- [ ] Split an epoch group at a block boundary — verify two groups with correct blocks
- [ ] Delete an epoch or block — verify removed from tree
- [ ] Record 800+ short epochs — verify no delay when starting a new epoch group

### MeanResponseFigure Streaming
- [ ] Run a long epoch (>5s with streaming) — MeanResponseFigure shows preview during epoch
- [ ] After epoch completes — MeanResponseFigure shows full mean (not just preview)
- [ ] Run multiple long epochs — MeanResponseFigure accumulates running mean across epochs
- [ ] Verify no "gap in the middle" artifact on MeanResponseFigure

### Partial Save
- [ ] Record a long epoch, click Stop — verify Save/Discard/Cancel dialog appears
- [ ] Choose Save — verify partial epoch saved in Data Manager
- [ ] At 20 kHz — verify partial save works (not just 10 kHz)
- [ ] Verify MATLAB does not crash on partial save with streaming enabled

---

## Post-Test Verification

- [ ] Close all files
- [ ] Close SymphonyApp — cleanup runs without error
- [ ] Open recorded .h5 files with `h5disp` — valid HDF5 structure
- [ ] Run `symphonyui.ui.profileAcquisition()` — all timings reasonable
- [ ] Run `symphonyui.ui.runEndToEndTests()` — 10/10 pass
- [ ] Check `streaming_debug.log` in user profile — no unexpected errors
- [ ] Verify `HekaITCProxy.exe` terminates when SymphonyApp closes

---

## Notes

Record any issues, error messages, or unexpected behavior here:

| Test | Issue | Severity | Notes |
|------|-------|----------|-------|
|      |       |          |       |
|      |       |          |       |
|      |       |          |       |
