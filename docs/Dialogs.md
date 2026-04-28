# Symphony Dialogs

All modal and non-modal dialogs in Symphony are built with MATLAB's `uifigure` framework. This document covers the keyboard behavior, dialog lifecycle, and implementation patterns.

---

## Keyboard Shortcuts

Every dialog supports **Enter** and **Escape** keyboard shortcuts:

| Dialog | Enter | Escape | Modal |
|--------|-------|--------|-------|
| Initialize Rig | Initialize selected rig | Cancel | Yes |
| New File | Save file | Cancel | Yes |
| Begin Epoch Group | Begin epoch group | Cancel | Yes |
| Add Source | Add source | Cancel | Yes |
| Configure Devices | OK (close) | OK (close) | Yes |
| Options | Save all settings | Cancel (discard changes) | Yes |
| Protocol Presets | Apply selected preset | Close | No |

### How It Works

MATLAB's `uifigure` only fires `KeyPressFcn` on the figure itself — not when a child control (dropdown, edit field, checkbox) has focus. To ensure Enter/Escape work from any control, all dialogs use the shared utility:

```matlab
ui.DialogUtil.setKeyPressFcnRecursive(obj.fig, @(~,e)obj.onKeyPress(e));
```

This recursively sets `KeyPressFcn` on every interactive child control in the figure, so the dialog's `onKeyPress` handler fires regardless of which control has focus.

### Adding Keyboard Support to a New Dialog

1. Add `KeyPressFcn` to the `uifigure` constructor:
   ```matlab
   obj.fig = uifigure(..., 'KeyPressFcn', @(~,e)obj.onKeyPress(e));
   ```

2. At the end of `buildUi` (after all controls are created), propagate to children:
   ```matlab
   ui.DialogUtil.setKeyPressFcnRecursive(obj.fig, @(~,e)obj.onKeyPress(e));
   ```

3. Implement `onKeyPress`:
   ```matlab
   function onKeyPress(obj, event)
       switch event.Key
           case 'return'
               obj.onPrimaryAction();
           case 'escape'
               obj.onCancel();
       end
   end
   ```

---

## Dialog Reference

### Initialize Rig (`InitializeRigDialog`)

**Menu:** Configure > Initialize Rig (also opens automatically at startup)

Scans the configured search paths for `symphonyui.core.descriptions.RigDescription` subclasses and displays them in a dropdown. Selecting a rig constructs the `RigDescription`, wraps it in a `symphonyui.core.Rig`, and assigns it to the controller.

**Controls:**
- Description dropdown — lists available rig descriptions
- Initialize button — constructs and initializes the selected rig
- Cancel button — closes without initializing

---

### New File (`NewFileDialog`)

**Menu:** File > New

Creates a new HDF5 data file via `host.CreateFileAsync()`. The default file name and location come from `symphonyui.app.Options` (see [Options](Options.md)).

**Controls:**
- Name field — file name (auto-populated from Options default name)
- Location field + Browse button — directory path
- Save button — creates the file
- Cancel button — closes without creating

---

### Begin Epoch Group (`BeginEpochGroupDialog`)

**Menu:** Document > Begin Epoch Group (also available via Data Manager menu and context menu)

Scans search paths for `EpochGroupDescription` subclasses. Each description defines metadata properties (e.g., external solution, recording technique) that are persisted to HDF5.

**Controls:**
- Description dropdown — epoch group type (Control, Drug, Wash, etc.)
- Label field — auto-populated from description name, editable
- Source dropdown — defaults to the deepest leaf source in the hierarchy
- Carry forward checkbox — copies properties from the previous epoch group
- Begin button — opens the epoch group

---

### Add Source (`AddSourceDialog`)

**Menu:** Document > Add Source (also available via Data Manager context menu "Add Child Source")

Scans search paths for `SourceDescription` subclasses. The available types are filtered based on the current source hierarchy:

- **No sources exist:** only top-level types (Subject subclasses) are shown
- **Adding a child source:** only types whose `addAllowableParentType` matches the selected parent are shown
- **Namespace filtering:** child sources are restricted to the same namespace as the parent (e.g., `io.sources.animal.Animal` only shows `io.sources.animal.Preparation` as a child, not `io.github.symphony_das.sources.Preparation`)

**Controls:**
- Description dropdown — source type, with namespace in parentheses
- Parent dropdown — parent source (pre-selected when adding a child)
- Label field — auto-populated, editable
- Add button — creates the source and persists description properties to HDF5
- Cancel button — closes without adding

---

### Configure Devices (`DevicesDialog`)

**Menu:** Configure > Devices

Displays all devices in the current rig with their properties: name, manufacturer, input/output streams, background value, and configuration settings.

**Controls:**
- Device listbox — lists all rig devices
- Detail panel — shows selected device properties
- Configuration table — editable key/value pairs
- OK button — closes the dialog

---

### Options (`SymphonyOptionsDialog`)

**Menu:** Configure > Options

Application-wide settings organized in tabs. See [Options](Options.md) for full documentation.

**Controls:**
- General tab — startup file, cleanup file, view-only warning
- File tab — default name, location, cleanup function
- Search Path tab — directories for class discovery
- Logging tab — log configuration and directory
- Save button — persists all changes
- Default button — resets to default values
- Cancel button — discards changes

---

### Protocol Presets (`ProtocolPresetsDialog`)

**Menu:** Configure > Protocol Presets

Manages saved protocol parameter configurations. Non-modal — stays open while using the main app.

**Controls:**
- Preset listbox — saved presets (protocol name shown in parentheses)
- Add button — saves current protocol parameters as a named preset
- Apply button — loads selected preset's parameters into the protocol
- Remove button — deletes the selected preset
- View Only / Record buttons — applies the preset and starts acquisition
- Double-click — same as Apply

The Record button is disabled when no epoch group is open. Button states refresh automatically every 2 seconds via a timer.

---

## Dialog Lifecycle

### Modal Dialogs

Most dialogs use `uiwait`/`uiresume` for blocking behavior:

```matlab
% Static factory method
function result = showBlocking(parentFigure, ...)
    dlg = MyDialog(parentFigure, ...);
    dlg.fig.Visible = 'on';
    uiwait(dlg.fig);
    result = dlg.result;
end
```

The dialog sets `obj.result` before calling `uiresume` + `delete(obj.fig)`. The caller receives the result after `uiwait` returns.

### Non-Modal Dialogs

`ProtocolPresetsDialog` is non-modal (`WindowStyle` not set to `'modal'`). It uses a 2-second timer to refresh button states and stays open until explicitly closed.

### Position Persistence

Dialog positions are saved and restored via MATLAB preferences using `setpref`/`getpref` under the `'symphony_ui'` group. Each dialog uses a unique key based on its class name.

---

## DialogUtil Reference

`ui.DialogUtil` provides shared utilities for all dialogs:

### `setKeyPressFcnRecursive(parent, fcn)`

Recursively sets `KeyPressFcn` on all interactive children of `parent`. This includes:
- `uidropdown`
- `uieditfield`
- `uicheckbox`
- `uilistbox`
- `uitextarea`
- Any other control with a `KeyPressFcn` property

**Usage:**
```matlab
ui.DialogUtil.setKeyPressFcnRecursive(obj.fig, @(~,e)obj.onKeyPress(e));
```

Call this at the end of `buildUi`, after all controls have been created.
