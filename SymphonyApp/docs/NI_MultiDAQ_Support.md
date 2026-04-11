# NI DAQ Multi-Device Support

### Background

The original `NIDAQController` supported a single NI device (e.g., `"Dev1"`). Some rigs use multiple NI boards to get more analog channels. The controller now supports any number of devices with automatic cross-device clock synchronization.

### Usage

The constructor accepts any of these forms:

**From C#:**
```csharp
new NIDAQController("Dev1")                                  // single device
new NIDAQController("Dev1,Dev2,Dev3")                        // comma-delimited
new NIDAQController("Dev1;Dev2;Dev3")                        // semicolon-delimited
new NIDAQController(new[] { "Dev1", "Dev2", "Dev3" })        // string array
new NIDAQController(new List<string> { "Dev1", "Dev2" })     // list
```

**From MATLAB:**
```matlab
daq = NiDaqController('Dev1');                    % single device
daq = NiDaqController('Dev1,Dev2,Dev3');          % comma-delimited
daq = NiDaqController({'Dev1','Dev2','Dev3'});    % cell array
```

### Stream Naming

With a single device, streams use short names (backwards compatible):
```
ai0, ai1, ao0, ao1, diport0, doport0
```

With multiple devices, streams are prefixed with the device name to avoid collisions:
```
Dev1_ai0, Dev1_ao0, Dev2_ai0, Dev2_ao0, Dev1_diport0, Dev2_doport0
```

### Cross-Device Synchronization

The first device in the list is the **master**. All other devices are **slaves**.

**Master device:**
- Runs on its own internal sample clock
- Exports its sample clock and start trigger signals for slave devices to import

**Slave devices:**
- Import the master's sample clock via a physical route (RTSI cable or PXI backplane)
- Import the master's start trigger to ensure all devices start simultaneously

**Within each device**, one DAQ task is the local master:
- The local master task uses the device's internal clock (or the imported global master clock for slave devices)
- Other local tasks (e.g., AI, AO, DI, DO) sync to the local master's `SampleClock` and `StartTrigger`

**Start sequence:**
1. Slave device tasks are started first (they wait for the master's trigger)
2. Master device's slave tasks are started
3. Master device's master task is started last (triggers all devices simultaneously)

**Hardware requirement:** Multi-device synchronization requires a physical connection between devices — either a RTSI cable (for PCI/PCIe boards) or a shared PXI backplane (for PXI systems).

### Output Write Sequencing

To prevent digital output buffer overflow errors (`-200292`), analog and digital writes are performed **sequentially** rather than in parallel:

1. **Analog output writes first** — the analog output typically provides the sample clock that drives digital output timing
2. **Digital output writes second** — with retry logic for buffer-full conditions

The digital write includes a retry loop (200 retries, 5ms delay) to handle cases where the hardware hasn't consumed previous data yet:

```csharp
for (int retry = 0; retry <= maxRetries; retry++)
{
    try
    {
        writer.WriteMultiSamplePort(false, data);
        return;
    }
    catch (DaqException ex) when (ex.Error == -200292)
    {
        if (retry == maxRetries) throw;
        Thread.Sleep(retryDelayMs);
    }
}
```

This replaced the previous parallel write approach (`Task.Factory.StartNew` for analog and digital simultaneously) which caused buffer overflows because the digital hardware clock hadn't started when digital data was being written.

### Input Read Handling

Input reads (AI and DI) remain parallelized across devices for efficiency, since reads don't have the same buffer overflow concerns as writes. Each device's analog and digital inputs are read in separate tasks and combined into the result set.

Reads use chunked transfer blocks (`TRANSFER_BLOCK_SAMPLES = 512`) with polling for available samples:

```csharp
while (container.AIStream.AvailableSamplesPerChannel < toRead
       && !token.IsCancellationRequested)
{
    Thread.Sleep(1);
}
```

### Rig Configuration Example

```matlab
classdef DualNiDaqRig < symphonyui.core.descriptions.RigDescription
    methods
        function obj = DualNiDaqRig()
            import symphonyui.builtin.daqs.*;
            import symphonyui.builtin.devices.*;
            import symphonyui.core.*;

            % Create controller with two NI devices
            daq = NiDaqController('Dev1,Dev2');
            obj.daqController = daq;

            % Dev1 channels — use prefixed names
            amp1 = MultiClampDevice('Amp1', 1) ...
                .bindStream(daq.getStream('Dev1_ao0')) ...
                .bindStream(daq.getStream('Dev1_ai0'));
            obj.addDevice(amp1);

            % Dev2 channels — additional analog I/O
            amp2 = MultiClampDevice('Amp2', 2) ...
                .bindStream(daq.getStream('Dev2_ao0')) ...
                .bindStream(daq.getStream('Dev2_ai0'));
            obj.addDevice(amp2);

            % LEDs on Dev1
            green = UnitConvertingDevice('Green LED', 'V') ...
                .bindStream(daq.getStream('Dev1_ao2'));
            obj.addDevice(green);

            % Additional inputs on Dev2
            photodiode = UnitConvertingDevice('Photodiode', 'V') ...
                .bindStream(daq.getStream('Dev2_ai1'));
            obj.addDevice(photodiode);
        end
    end
end
```

### Changed Files

| File | Project | Description |
|------|---------|-------------|
| `NIDAQController.cs` | NIDAQController | Multi-device constructors, `ParseDeviceNames`, prefixed stream naming, sequential write dispatch. |
| `MultiDeviceNIHardwareDevice.cs` | NIDAQController | New class. Manages per-device `DAQTaskContainer` instances with cross-device master/slave clock synchronization, sequential analog-then-digital writes, retry logic for digital output, and parallelized reads. |
| `NIHardwareDevice.cs` | NIDAQController | Updated with chunked write retry logic and sequential write ordering (same fixes as multi-device). |
| `NiDaqController.m` | MATLAB | Updated to accept cell arrays and delimited strings. |

### Known Issue: DIPorts/DOPorts Swapped

In the original `NIHardwareDevice.cs`, the `DIPorts` and `DOPorts` properties are swapped. This is fixed in `MultiDeviceNIHardwareDevice`. Consider fixing it in `NIHardwareDevice` as well.
