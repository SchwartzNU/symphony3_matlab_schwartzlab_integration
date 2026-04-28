function preloadHekaDriver()
%PRELOADHEKADRIVER  Force ITCMM.dll to load below 4 GB.
%   Must be called BEFORE any NET.addAssembly call. ITCMM.dll uses internal
%   32-bit pointer arithmetic and crashes when loaded above 4 GB.
%
%   Strategy: copy ITCMM.dll to a local directory, patch the PE header to
%   disable ASLR (clear the DYNAMICBASE flag), then LoadLibrary the patched
%   copy. Without ASLR, Windows loads the DLL at its preferred base (below 4GB).
%
%   The patched copy is cached so the PE patching only happens once.

    if ~ispc
        return;
    end

    % Locate the system ITCMM.dll
    sysItcmm = fullfile(getenv('SYSTEMROOT'), 'System32', 'ITCMM.dll');
    if ~isfile(sysItcmm)
        w = which('ITCMM.dll');
        if ~isempty(w)
            sysItcmm = w;
        else
            return;  % No HEKA driver installed
        end
    end

    fprintf('preloadHekaDriver: system ITCMM.dll at %s\n', sysItcmm);

    % Create a local patched copy with ASLR disabled
    appDir = fileparts(mfilename('fullpath'));
    localDir = fullfile(appDir, 'heka_native');
    localItcmm = fullfile(localDir, 'ITCMM.dll');

    if ~isfolder(localDir)
        mkdir(localDir);
    end

    % Check if we need to (re)create the patched copy
    needsPatch = false;
    if ~isfile(localItcmm)
        needsPatch = true;
    else
        % Check if system DLL is newer
        sysInfo = dir(sysItcmm);
        localInfo = dir(localItcmm);
        if sysInfo.datenum > localInfo.datenum
            needsPatch = true;
        end
    end

    if needsPatch
        fprintf('preloadHekaDriver: creating ASLR-disabled copy...\n');
        try
            copyfile(sysItcmm, localItcmm, 'f');
            disableAslrInPE(localItcmm);
            fprintf('preloadHekaDriver: patched copy created at %s\n', localItcmm);
        catch ex
            fprintf(2, 'preloadHekaDriver: failed to create patched copy: %s\n', ex.message);
            % Fall back to system copy
            localItcmm = sysItcmm;
        end
    end

    % Also copy any companion DLLs that ITCMM.dll depends on
    companionDlls = {'ITCMM_USB.dll', 'ITCMM_PCI.dll'};
    for i = 1:numel(companionDlls)
        sysDll = fullfile(getenv('SYSTEMROOT'), 'System32', companionDlls{i});
        if isfile(sysDll)
            localDll = fullfile(localDir, companionDlls{i});
            if ~isfile(localDll) || dir(sysDll).datenum > dir(localDll).datenum
                try
                    copyfile(sysDll, localDll, 'f');
                catch
                end
            end
        end
    end

    % Add the local directory to the system PATH so DLL dependencies resolve
    currentPath = getenv('PATH');
    if ~contains(currentPath, localDir)
        setenv('PATH', [localDir ';' currentPath]);
    end

    % Ensure the MEX loader is compiled
    mexName = 'loadDllAtBase';
    mexFile = fullfile(appDir, [mexName '.' mexext]);
    if ~isfile(mexFile)
        srcFile = fullfile(tempdir, [mexName '.c']);
        writeMexSource(srcFile);
        fprintf('preloadHekaDriver: compiling MEX helper...\n');
        try
            mex('-O', '-output', fullfile(appDir, mexName), srcFile);
            fprintf('preloadHekaDriver: MEX compiled.\n');
        catch ex
            fprintf(2, 'preloadHekaDriver: MEX compile failed: %s\n', ex.message);
            % Try loadlibrary fallback
            try
                loadlibrary(localItcmm, @itcmmPreloadProto, 'alias', 'ITCMM_preload');
                fprintf('preloadHekaDriver: loaded via loadlibrary.\n');
            catch
                fprintf(2, 'preloadHekaDriver: all strategies failed.\n');
            end
            return;
        end
    end

    % Load the patched DLL via MEX
    try
        [h, addr] = loadDllAtBase(localItcmm);
        if h == 0
            fprintf(2, 'preloadHekaDriver: LoadLibrary returned NULL.\n');
            return;
        end
        if addr > hex2dec('FFFFFFFF')
            fprintf(2, 'preloadHekaDriver: WARNING — still above 4GB at 0x%X\n', uint64(addr));
            fprintf(2, '  ASLR patch may not have taken effect. Check file permissions.\n');
        else
            fprintf('preloadHekaDriver: ITCMM.dll loaded at 0x%X (below 4GB, OK)\n', uint64(addr));
        end
    catch ex
        fprintf(2, 'preloadHekaDriver: MEX load failed: %s\n', ex.message);
    end
end

function disableAslrInPE(filepath)
%DISABLEASLRINPE  Clear the IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE flag in a PE file.
%   This tells the Windows loader NOT to apply ASLR to this DLL, so it loads
%   at its preferred ImageBase address (typically below 4 GB).
%
%   The flag is bit 0x0040 in DllCharacteristics, located in the PE optional header.

    fid = fopen(filepath, 'r+', 'l');  % little-endian
    if fid < 0
        error('Cannot open %s for writing', filepath);
    end
    c = onCleanup(@()fclose(fid));

    % Read DOS header — e_lfanew is at offset 0x3C (4 bytes)
    fseek(fid, hex2dec('3C'), 'bof');
    e_lfanew = fread(fid, 1, 'uint32');

    % Verify PE signature
    fseek(fid, e_lfanew, 'bof');
    peSig = fread(fid, 1, 'uint32');
    if peSig ~= hex2dec('4550')  % 'PE\0\0'
        error('Not a valid PE file');
    end

    % IMAGE_FILE_HEADER is 20 bytes after PE signature
    % Skip IMAGE_FILE_HEADER (20 bytes) to get to Optional Header
    % DllCharacteristics offset depends on PE32 vs PE32+:
    %   PE32  (32-bit): Optional Header offset + 70 = e_lfanew + 4 + 20 + 70
    %   PE32+ (64-bit): Optional Header offset + 70 = e_lfanew + 4 + 20 + 70
    % Actually, DllCharacteristics is at offset 70 in PE32+ and 70 in PE32.
    % Wait — let me be precise:
    %   PE32:  OptionalHeader starts at e_lfanew+24, DllCharacteristics at +46 into OptHeader = +70 total
    %          Actually: offset 46 in IMAGE_OPTIONAL_HEADER32
    %   PE32+: offset 46 is different. Let me read the Magic first.

    optHeaderStart = e_lfanew + 4 + 20;  % after PE sig + FILE_HEADER
    fseek(fid, optHeaderStart, 'bof');
    magic = fread(fid, 1, 'uint16');

    if magic == hex2dec('10B')       % PE32
        dllCharOffset = optHeaderStart + 46;
    elseif magic == hex2dec('20B')   % PE32+ (64-bit)
        dllCharOffset = optHeaderStart + 70;
    else
        error('Unknown PE optional header magic: 0x%X', magic);
    end

    % Read current DllCharacteristics
    fseek(fid, dllCharOffset, 'bof');
    dllChar = fread(fid, 1, 'uint16');

    DYNAMIC_BASE = hex2dec('0040');
    HIGH_ENTROPY_VA = hex2dec('0020');

    if bitand(dllChar, DYNAMIC_BASE)
        % Clear DYNAMIC_BASE and HIGH_ENTROPY_VA flags
        newDllChar = bitand(dllChar, bitcmp(bitor(DYNAMIC_BASE, HIGH_ENTROPY_VA), 'uint16'));
        fseek(fid, dllCharOffset, 'bof');
        fwrite(fid, newDllChar, 'uint16');
        fprintf('preloadHekaDriver: cleared ASLR flags (0x%04X -> 0x%04X)\n', dllChar, newDllChar);
    else
        fprintf('preloadHekaDriver: ASLR already disabled (DllCharacteristics=0x%04X)\n', dllChar);
    end
end

function [methodinfo, structs, enuminfo, ThunkLibName] = itcmmPreloadProto()
    structs  = [];
    enuminfo = [];
    ThunkLibName = [];
    fcns = struct( ...
        'name',      {{'ITC_Devices'}}, ...
        'calltype',  {{'cdecl'}}, ...
        'LHS',       {{{{'uint32'}}}}, ...
        'RHS',       {{{{'uint32', 'uint32Ptr'}}}}, ...
        'alias',     {{'ITC_Devices'}});
    methodinfo = fcns;
end

function writeMexSource(filepath)
%WRITEMEXSOURCE  MEX that calls LoadLibraryA and returns [handle, baseAddress].
    fid = fopen(filepath, 'w');
    if fid < 0, error('Cannot write %s', filepath); end
    c = onCleanup(@()fclose(fid));
    src = { ...
        '#include "mex.h"'
        '#include <windows.h>'
        ''
        'void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {'
        '    char path[2048];'
        '    HMODULE hMod;'
        '    if (nrhs < 1 || !mxIsChar(prhs[0]))'
        '        mexErrMsgIdAndTxt("loadDll:input", "Provide DLL path.");'
        '    mxGetString(prhs[0], path, sizeof(path));'
        ''
        '    /* Check if already loaded */'
        '    hMod = GetModuleHandleA("ITCMM.dll");'
        '    if (!hMod) hMod = LoadLibraryA(path);'
        ''
        '    if (!hMod) {'
        '        mexPrintf("loadDllAtBase: LoadLibrary failed (error %lu)\\n", GetLastError());'
        '        if (nlhs > 0) plhs[0] = mxCreateDoubleScalar(0);'
        '        if (nlhs > 1) plhs[1] = mxCreateDoubleScalar(0);'
        '        return;'
        '    }'
        ''
        '    double addr = (double)(uintptr_t)hMod;'
        '    mexPrintf("loadDllAtBase: ITCMM.dll at 0x%llX\\n", (unsigned long long)(uintptr_t)hMod);'
        '    if (nlhs > 0) plhs[0] = mxCreateDoubleScalar(addr);'
        '    if (nlhs > 1) plhs[1] = mxCreateDoubleScalar(addr);'
        '}'
    };
    for i = 1:numel(src)
        fprintf(fid, '%s\n', src{i});
    end
end
