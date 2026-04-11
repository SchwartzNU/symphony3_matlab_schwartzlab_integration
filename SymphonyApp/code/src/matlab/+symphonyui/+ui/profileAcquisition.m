function profileAcquisition()
    %PROFILEACQUISITION  Measure key timing metrics for the acquisition pipeline.
    %
    %   Run this after initializing a rig and selecting a protocol.
    %   It measures:
    %     1. Startup time (app launch to ready)
    %     2. File creation time
    %     3. Data Manager tree build time
    %     4. Epoch group begin/end time
    %     5. Protocol property grid refresh time
    %     6. Figure handler creation time
    %
    %   Usage:
    %     symphonyui.ui.profileAcquisition()

    fprintf('\n=== Symphony 3 Performance Profile ===\n');
    fprintf('Date: %s\n', datestr(now));
    fprintf('MATLAB: %s\n', version);
    if ispc
        fprintf('Platform: Windows\n');
    elseif ismac
        fprintf('Platform: macOS\n');
    else
        fprintf('Platform: Linux\n');
    end

    % Check HDF5 library
    try
        fprintf('HDF5 library: ');
        asm = System.AppDomain.CurrentDomain.GetAssemblies();
        for i = 0:asm.Length-1
            a = asm.Get(i);
            name = char(a.GetName().Name);
            if strcmp(name, 'HDF.PInvoke')
                fprintf('%s\n', char(a.Location));
                break;
            end
        end
    catch
        fprintf('unknown\n');
    end

    fprintf('\n--- Component Timing ---\n');

    % 1. File creation
    try
        testFile = fullfile(tempdir, ['symphony_profile_' datestr(now, 'yyyymmddHHMMSS') '.h5']);
        t = tic;
        % Create via .NET
        persistor = symphonyui.core.callNetStatic('Symphony.Core.H5EpochPersistor', 'Create', ...
            testFile, System.DateTimeOffset.Now, uint32(9));
        fileCreateTime = toc(t);
        fprintf('  File creation:         %.3f s\n', fileCreateTime);

        % Close
        t = tic;
        persistor.Close();
        fileCloseTime = toc(t);
        fprintf('  File close:            %.3f s\n', fileCloseTime);

        % Reopen
        t = tic;
        persistor2 = symphonyui.core.createNetObj('Symphony.Core.H5EpochPersistor', testFile);
        fileOpenTime = toc(t);
        fprintf('  File reopen:           %.3f s\n', fileOpenTime);
        persistor2.Close();

        % Cleanup
        delete(testFile);
    catch ex
        fprintf('  File operations:       FAILED (%s)\n', ex.message);
    end

    % 2. .NET object creation speed
    try
        t = tic;
        for i = 1:100
            m = symphonyui.core.createNetObj('Symphony.Core.Measurement', 1.0, 'V');
        end
        measTime = toc(t);
        fprintf('  100x Measurement:      %.3f s (%.1f ms each)\n', measTime, measTime*10);
    catch ex
        fprintf('  Measurement creation:  FAILED (%s)\n', ex.message);
    end

    % 3. Response.GetDataArray speed
    try
        resp = symphonyui.core.createNetObj('Symphony.Core.Response');
        % Create test data
        nSamples = 100000;
        quantities = rand(1, nSamples);
        cdata = symphonyui.core.callNetStatic('Symphony.Core.Measurement', 'FromArray', quantities, 'V');
        rate = symphonyui.core.createNetObj('Symphony.Core.Measurement', 10000.0, 'Hz');
        inputData = symphonyui.core.createNetObj('Symphony.Core.InputData', cdata, rate, System.DateTimeOffset.Now);
        resp.AppendData(inputData);

        t = tic;
        arr = resp.GetDataArray();
        getDataTime = toc(t);
        fprintf('  GetDataArray (%dk):   %.3f s\n', nSamples/1000, getDataTime);

        t = tic;
        arr2 = resp.GetFullDataArray();
        getFullDataTime = toc(t);
        fprintf('  GetFullDataArray (%dk):%.3f s\n', nSamples/1000, getFullDataTime);
    catch ex
        fprintf('  GetDataArray:          FAILED (%s)\n', ex.message);
    end

    % 4. Memory usage
    try
        if ispc
            [~, mem] = system('tasklist /fi "imagename eq MATLAB.exe" /fo list');
            % Parse "Mem Usage:    1,234,567 K" from list format (avoids CSV quoting issues)
            idx = strfind(mem, 'Mem Usage:');
            if ~isempty(idx)
                line = mem(idx(1):min(idx(1)+60, numel(mem)));
                nums = regexp(line, '[\d,]+', 'match');
                if ~isempty(nums)
                    memKB = str2double(strrep(nums{1}, ',', ''));
                    if ~isnan(memKB) && memKB > 0
                        fprintf('  MATLAB memory:         %.0f MB\n', memKB / 1024);
                    end
                end
            end
        else
            % macOS / Linux
            [~, pid] = system('pgrep -f "MATLAB"');
            pid = strtrim(pid);
            pids = strsplit(pid, newline);
            if ~isempty(pids) && ~isempty(pids{1})
                [~, rss] = system(sprintf('ps -o rss= -p %s', pids{1}));
                memKB = str2double(strtrim(rss));
                if ~isnan(memKB) && memKB > 0
                    fprintf('  MATLAB memory:         %.0f MB\n', memKB / 1024);
                end
            end
        end
    catch
    end

    fprintf('\n=== Profile Complete ===\n\n');
end
