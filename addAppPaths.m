function addAppPaths()

appDir = fileparts(mfilename('fullpath'));
addpath(appDir);  % Ensure SymphonyApp.m is on the path regardless of pwd
addpath(genpath(fullfile(appDir, 'code', 'lib')));
addpath(fullfile(appDir, 'code', 'src', 'matlab'));

% Platform-specific setup before loading .NET assemblies
if ispc
    % Pre-load ITCMM.dll BEFORE .NET CLR initialization — but only if
    % the Heka ITC driver is installed on this machine.
    itcmmPath = fullfile(getenv('SYSTEMROOT'), 'System32', 'ITCMM.dll');
    if isfile(itcmmPath)
        preloadHekaDriver();
    end
end

addAssemblies(appDir);

end

function addAssemblies(appDir)
% Load .NET assemblies from the consolidated core directory.
% Detects the platform and loads from the appropriate subfolder:
%   Windows:        code/core/win_x64    (net48)
%   macOS ARM64:    code/core/osx-arm64  (net10.0)
%   macOS Intel:    code/core/osx-x64    (net10.0)
%   Linux:          code/core/linux-x64  (net10.0)

coreDir = fullfile(appDir, 'code', 'core');

if ispc
    platformDir = fullfile(coreDir, 'win_x64');
elseif ismac
    [~, cpuType] = system('uname -m');
    cpuType = strtrim(cpuType);
    if strcmp(cpuType, 'arm64')
        platformDir = fullfile(coreDir, 'osx-arm64');
    else
        platformDir = fullfile(coreDir, 'osx-x64');
    end
elseif isunix
    platformDir = fullfile(coreDir, 'linux-x64');
else
    error('Unsupported platform');
end

coreDll = fullfile(platformDir, 'Symphony.Core.dll');
acqDll  = fullfile(platformDir, 'Symphony.Acquisition.dll');

if isfolder(platformDir) && isfile(coreDll)
    % Consolidated directory — all DLLs in one place
    addpath(platformDir);

    % Load assemblies in dependency order. On macOS/Linux, .NET doesn't
    % automatically resolve dependencies from the same directory — each
    % assembly must be loaded explicitly before types that reference it.
    %
    % Configure log4net IMMEDIATELY after loading it to prevent it from
    % trying to read System.Configuration (unsupported on macOS .NET).
    depDlls = {'log4net.dll', 'HDF.PInvoke.dll', 'SymphonyHDF5.dll'};
    for i = 1:numel(depDlls)
        dllPath = fullfile(platformDir, depDlls{i});
        if isfile(dllPath)
            try
                NET.addAssembly(dllPath);
            catch ex
                % Was previously a silent `catch, end`. The swallowed
                % errors would cause Symphony.Core.dll to later fail
                % to resolve types from the missing dependency, with
                % a confusing "Unable to resolve the name ..." error
                % deep inside user code. Surfacing the real error here
                % tells you exactly which dependency broke and why.
                fprintf(2, 'addAppPaths: dependency %s FAILED to load:\n  %s\n', ...
                    depDlls{i}, ex.message);
            end
        else
            fprintf(2, 'addAppPaths: dependency %s is MISSING at %s\n', ...
                depDlls{i}, dllPath);
        end
    end

    try
        NET.addAssembly(coreDll);
        disp('Warming up...')
        warmupSymphonyCoreTypes(); 
    catch ex
        error('SymphonyApp:addAppPaths:coreLoadFailed', ...
            ['Symphony.Core.dll failed to load from %s.\n' ...
             'Underlying error: %s\n' ...
             'Check the dependency load messages above for the real cause.'], ...
            coreDll, ex.message);
    end

    % Load additional assemblies
    extraDlls = {'Symphony.SimulationDAQController.dll', 'Symphony.ExternalDevices.dll'};
    for i = 1:numel(extraDlls)
        dllPath = fullfile(platformDir, extraDlls{i});
        if isfile(dllPath)
            try
                NET.addAssembly(dllPath);
            catch ex
                fprintf(2, 'addAppPaths: %s FAILED to load:\n  %s\n', ...
                    extraDlls{i}, ex.message);
            end
        end
    end

    % Windows-only: eager-load ITCMM.dll for Heka DAQ support.
    % Only attempt if the Heka ITC driver is installed.
    if ispc
        itcmmPath = fullfile(getenv('SYSTEMROOT'), 'System32', 'ITCMM.dll');
        hekaInteropDll = fullfile(platformDir, 'HekaNativeInterop.dll');
        if isfile(itcmmPath) && isfile(hekaInteropDll)
            try
                NET.addAssembly(hekaInteropDll);
                Heka.NativeInterop.ITCMM.EnsureNativeLoaded();
            catch ex
                fprintf(2, 'addAppPaths: HekaNativeInterop eager load failed: %s\n', ex.message);
            end
        end
        % Load Windows-only DAQ controller assemblies
        winDlls = {'HekaDAQInterface.dll', 'HekaNativeInterop.dll', 'NIDAQInterface.dll'};
        for i = 1:numel(winDlls)
            dllPath = fullfile(platformDir, winDlls{i});
            if isfile(dllPath)
                try NET.addAssembly(dllPath); catch, end
            end
        end
    end

    NET.addAssembly(acqDll);
    fprintf('addAppPaths: loaded assemblies from %s\n', platformDir);
else
    % Fallback: load from individual build output directories
    srcDir = fullfile(fileparts(appDir), 'symphony-core', 'symphony-core');
    if ispc
        build_type = 'Release';
        framework_name = 'net48';
    else
        build_type = 'Release';
        framework_name = 'net10.0';
    end

    NET.addAssembly(fullfile(srcDir, 'Symphony.Core', 'bin', build_type, framework_name, 'Symphony.Core.dll'));

    % Windows-only: eager-load ITCMM.dll (only if Heka driver installed)
    if ispc
        itcmmPath = fullfile(getenv('SYSTEMROOT'), 'System32', 'ITCMM.dll');
        hekaDir = fullfile(srcDir, 'HekaNativeInterop', 'bin', build_type, framework_name);
        hekaInteropDll = fullfile(hekaDir, 'HekaNativeInterop.dll');
        if isfile(itcmmPath) && isfile(hekaInteropDll)
            try
                addpath(hekaDir);
                NET.addAssembly(hekaInteropDll);
                Heka.NativeInterop.ITCMM.EnsureNativeLoaded();
            catch ex
                fprintf(2, 'addAppPaths: HekaNativeInterop eager load failed: %s\n', ex.message);
            end
        end
    end

    NET.addAssembly(fullfile(srcDir, 'Symphony.Acquisition', 'bin', build_type, framework_name, 'Symphony.Acquisition.dll'));

    % Add DAQ controller directories to path (Windows only for Heka/NI)
    assemblyDirs = {};
    if ispc
        assemblyDirs = { ...
            fullfile(srcDir, 'HekaDAQController',              'bin', build_type, framework_name), ...
            fullfile(srcDir, 'NIDAQController',                'bin', build_type, framework_name) };
    end
    % Cross-platform DAQ controllers
    assemblyDirs = [assemblyDirs, { ...
        fullfile(srcDir, 'Symphony.SimulationDAQController','bin', build_type, framework_name), ...
        fullfile(srcDir, 'Symphony.ExternalDevices',       'bin', build_type, framework_name) }];

    for i = 1:numel(assemblyDirs)
        d = assemblyDirs{i};
        if isfolder(d)
            addpath(d);
        end
    end
    fprintf('addAppPaths: loaded assemblies from build directories under %s\n', srcDir);
end
end
