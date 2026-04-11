# Construction area for upgrading Symphony2 -> Symphony3

This respository is currently under development to upgrade the core C# and Matlab wrapper code for the Symphony Data Acquisition System ([Symphony-DAS repository](https://github.com/Symphony-DAS)) developed in collaboration between Fred Rieke and Mike Manookin's laboratories. 

## Why update/upgrade?

The Symphony2 codebase has accumulated several critical issues that necessitate a ground-up modernization effort:
 
- **.NET Framework 4.5 is end-of-life.** Microsoft ended support for .NET 4.5 years ago. Security patches, bug fixes, and compatibility updates are no longer provided. Symphony3 targets .NET Framework 4.8 and .NET 10, both of which are actively supported.
 
- **Symphony doesn't run on newer versions of MATLAB.** The C++/CLI interop layer, 32-bit dependencies, and legacy UI components are incompatible with MATLAB R2024b and later. Symphony3 uses pure C# interop that works with modern 64-bit MATLAB.
 
- **The HDF5 interface is slow.** The original HDF5 persistence layer writes all epoch data in a single bulk operation at epoch completion. This is adequate for short epochs but causes multi-second pauses for long recordings and risks total data loss on crash. Symphony3 introduces streaming persistence with incremental HDF5 writes and crash recovery.
 
- **The UI is no longer supported in newer versions of MATLAB.** Symphony2's Java-based Swing UI components are deprecated in recent MATLAB releases. The framework is being restructured so that UI and non-DAQ libraries can eventually run on Mac and Linux.
 
- **Major errors in the NI-DAQ code affect data integrity.** The original `NIHardwareDevice` has swapped DI/DO port properties, and the single-device architecture prevents use of multiple NI boards for expanded channel counts. Symphony3 fixes these bugs and adds multi-device synchronization support.
 
- **The HEKA ITC-18 driver crashes on 64-bit systems.** A threading bug in the C++/CLI bridge layer causes a deterministic crash in the 64-bit ITCMM.dll underrun recovery path. Symphony3 replaces the C++/CLI bridge with a pure C# implementation that eliminates the crash entirely.

## Current state of the migration

This has been a massive migration effort. Here's a quick summary of where things stand:

**Working:**

- Full acquisition pipeline (Heka + NI-DAQ)
- Data persistence to HDF5 (backward-compatible with Symphony 2)
- Optional streaming data acquistion with configurable threshold
- Partial epoch save
- [Multi-device NI-DAQ support](SymphonyApp/docs/NI_MultiDAQ_Support.md)
- Cross-platform support (Windows + macOS + Linux)
- All UI dialogs, Data Manager, figure handlers
- Protocol presets export/import
- Source/EpochGroup description system

**Known issues to monitor:**

- HDF5 abort() crash on the target machine (mitigated by pausing Data Manager during acquisition)
- ITCMM.dll ASLR workaround needs to be applied per-machine: See [HEKA ITC Special Instructions](#heka-itc-special-instructions)

## Installation

The UI should work with Matlab R2022b+, but has only currently been tested on R2024b on Windows (x64) and Mac (ARM64).

Currently, the Windows and non-Windows versions are targeted for different .NET platforms: .NET 4.8 and .NET 10.0, respectively. Ideally, everything would be targeted to the latest version of .NET, but this is currently not possible because National Instruments has not updated their .NET API for quite some time. Several technical support posts from NI indicate that they are actively updating their API for the new .NET Core and when the NIDAQmx API is upgraded, I will retarget the Windows assemblies to the latest version of .NET possible.

In practicality, this means that installing for Windows and non-Windows environments requires a different procedure.

### Windows Installation

1. [Install the .NET 4.8 Runtime or SDK](https://dotnet.microsoft.com/en-us/download/dotnet-framework/net48)

2. Verify and Enable .NET Framework 4.8 
    - Before configuring MATLAB, ensure .NET 4.8 is active on your Windows machine:
    - Enable in Windows Features: Open the "Turn Windows features on or off" menu by searching for it in the Start menu. Ensure that .NET Framework 4.8 Advanced Services is checked.
    - Verify Installation: You can confirm the version by checking the Windows Registry at HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full. [More information](https://us-kb.sage.com/portal/app/portlets/results/viewsolution.jsp?solutionid=221924560117234&hypermediatext=null)

3. Set the .NET Runtime in MATLAB 
    - For modern versions of MATLAB (R2022b and later), use the `dotnetenv` command to switch between environments. 
    - Switch to Framework: Run the following command in the MATLAB Command Window to set the environment to .NET Framework (which includes 4.8 on Windows):
```matlab
dotnetenv("framework")
```

- Verify the Change: Use the `NET.isNETSupported` function to check if the framework is properly recognized. [More information](https://www.mathworks.com/help/matlab/matlab_external/system-requirements-for-using-matlab-interface-to-net.html)

#### HEKA ITC Special Instructions

For more detailed information see [ITC Driver Bug](/SymphonyApp/docs/ITC_Driver_Bug.md)

On machines where `ITCMM.dll` loads above 4 GB, disable high-entropy ASLR for the MATLAB process via an elevated PowerShell command (i.e., start as administrator), replacing 'R2024b' with your Matlab version:

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


### Mac/Linux Installation


To configure MATLAB to use .NET 10.0 on macOS, you must ensure your MATLAB version supports modern .NET (Core) runtimes and then direct the internal environment to the correct installation path.

1. Install .NET 10.0 SDK
Before configuring MATLAB, download and install the .NET 10.0 SDK [from the official Microsoft .NET download page](https://dotnet.microsoft.com/en-us/download/dotnet/10.0). Ensure you select the version corresponding to your processor (Apple Silicon or Intel). 

2. Verify Installation Path
Open the macOS Terminal and verify that .NET is correctly installed and find its location: 
Type `dotnet --info`.
Look for the Base Path or DOTNET_ROOT. On macOS, this is typically /usr/local/share/dotnet. 

3. Configure the MATLAB Environment 
In the MATLAB Command Window, use the dotnetenv function to set the runtime to "core" (which covers .NET 5+) and specify the version. 

Set the environment:
```matlab
dotnetenv("core", Version="10.0")
```

Verify the status:
```matlab
e = dotnetenv
```

This should return a NETEnvironment object showing "core" as the runtime and "10.0" as the version. 

4. Troubleshoot Detection (If Needed)
If MATLAB does not automatically find the .NET 10.0 installation, you may need to manually set the DOTNET_ROOT environment variable: [More Information](https://www.scivision.dev/matlab-dotnet-linux-macos/#:~:text=Find%20the%20%E2%80%9Cdotnet%E2%80%9D%20executable%20and%20run%20dotnet,the%20directory%20that%20contains%20the%20%E2%80%9Cdotnet%E2%80%9D%20executable.)

Find the exact path to the dotnet executable (usually /usr/local/share/dotnet).
In MATLAB, run:
```matlab
setenv("DOTNET_ROOT", "/usr/local/share/dotnet")
```

To make this permanent, add the setenv and dotnetenv commands to your startup.m file:
```matlab
edit(fullfile(userpath,'startup.m'))
```

Add the following to the startup.m file:
```matlab
setenv("DOTNET_ROOT", "/usr/local/share/dotnet")
```

5. Confirm Support
Run the following command to ensure the .NET interface is ready for use:
```matlab
NET.isNETSupported
```
If it returns 1 (true), you can begin loading assemblies using NET.addAssembly. 

Note: Ensure you are using a recent version of MATLAB (R2023b or later recommended), as older versions may have limited support for newer .NET runtimes on macOS. 


## Detailed documentation of changes
For detailed technical documentation of all changes, see:

- [Updates in Symphony version 3](SymphonyApp/docs/Version3_Updates.md)

- [ITC driver bug](SymphonyApp/docs/ITC_Driver_Bug.md)

