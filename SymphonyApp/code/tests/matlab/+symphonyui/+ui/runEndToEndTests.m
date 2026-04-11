function runEndToEndTests()
%RUNENDTOENDTESTS  Automated end-to-end tests for Symphony 3.
%
%   Runs 10 tests covering: simulated acquisition (view-only and record),
%   data integrity, multi-epoch protocols, epoch group lifecycle,
%   PropertyDescriptor backward compatibility, streaming configuration,
%   HDF5 file integrity, the fixH5ForSymphony2 migration script, and
%   performance baselines.
%
%   All tests use a simulated rig (no hardware required) and clean up
%   temporary files automatically.
%
%   Usage:
%     symphonyui.ui.runEndToEndTests()

    fprintf('\n');
    fprintf('===========================================================\n');
    fprintf('  Symphony 3 — End-to-End Test Suite\n');
    fprintf('  Date: %s   MATLAB: %s\n', datestr(now), version);
    fprintf('===========================================================\n\n');

    % Bootstrap
    bootstrap();

    results = struct('name', {}, 'passed', {}, 'time', {}, 'error', {});

    results(end+1) = runTest('Simulated Acquisition (View Only)',    @test1_viewOnly);
    results(end+1) = runTest('Simulated Acquisition (Record)',       @test2_record);
    results(end+1) = runTest('Data Integrity',                       @test3_dataIntegrity);
    results(end+1) = runTest('Multi-Epoch (PulseFamily)',            @test4_pulseFamily);
    results(end+1) = runTest('Epoch Group Lifecycle',                @test5_epochGroupLifecycle);
    results(end+1) = runTest('PropertyDescriptor Compat',            @test6_propertyDescriptor);
    results(end+1) = runTest('Streaming Configuration',              @test7_streaming);
    results(end+1) = runTest('HDF5 File Integrity',                  @test8_hdf5Integrity);
    results(end+1) = runTest('fixH5ForSymphony2 Migration',          @test9_migration);
    results(end+1) = runTest('Performance Baseline',                 @test10_performance);

    % Summary
    nPass = sum([results.passed]);
    nFail = numel(results) - nPass;
    fprintf('\n===========================================================\n');
    fprintf('  RESULTS: %d passed, %d failed (of %d)\n', nPass, nFail, numel(results));
    fprintf('===========================================================\n');
    for i = 1:numel(results)
        if results(i).passed
            fprintf('  PASS  [%.2fs]  %s\n', results(i).time, results(i).name);
        else
            fprintf('  FAIL  [%.2fs]  %s — %s\n', results(i).time, results(i).name, results(i).error);
        end
    end
    fprintf('\n');
end

%% ========== Test Framework ==========

function bootstrap()
    % Ensure .NET assemblies and example classes are available
    % Navigate from code/tests/matlab/+symphonyui/+ui/ up to SymphonyApp/
    appDir = fileparts(fileparts(fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))))));
    % appDir should be SymphonyApp/

    % Run addAppPaths if Controller class is not yet available
    if ~exist('symphonyui.core.Controller', 'class')
        oldDir = cd(appDir);
        cleanup = onCleanup(@()cd(oldDir));
        addAppPaths();
    end

    % Add examples to path for rig/protocol classes
    exDir = fullfile(appDir, 'code', 'src', 'resources', 'examples');
    if isfolder(exDir) && ~contains(path, exDir)
        addpath(genpath(exDir));
    end
end

function result = runTest(name, testFcn)
    result.name = name;
    result.error = '';
    fprintf('  Running: %s ...', name);
    t = tic;
    try
        testFcn();
        result.passed = true;
        result.time = toc(t);
        fprintf(' PASS (%.2fs)\n', result.time);
    catch ex
        result.passed = false;
        result.time = toc(t);
        result.error = ex.message;
        fprintf(' FAIL (%.2fs)\n    %s\n', result.time, ex.message);
    end
end

function assert_(cond, msg)
    if ~cond
        error('symphonyui:test:assertion', '%s', msg);
    end
end

%% ========== Helpers ==========

function [rig, controller] = createSimRig()
    % Build a pure-simulation rig using UnitConvertingDevice (no MultiClamp
    % Commander required). The Pulse protocol looks for a device whose name
    % contains 'Amp', so we name ours 'Amp1'.
    import symphonyui.builtin.daqs.*;
    import symphonyui.builtin.devices.*;
    import symphonyui.core.*;

    rigDesc = symphonyui.core.descriptions.RigDescription();
    daq = NiSimulationDaqController();
    rigDesc.daqController = daq;

    amp1 = UnitConvertingDevice('Amp1', 'V').bindStream(daq.getStream('ao0')).bindStream(daq.getStream('ai0'));
    rigDesc.addDevice(amp1);

    amp2 = UnitConvertingDevice('Amp2', 'V').bindStream(daq.getStream('ao1')).bindStream(daq.getStream('ai1'));
    rigDesc.addDevice(amp2);

    rig = symphonyui.core.Rig(rigDesc);
    controller = symphonyui.core.Controller();
    controller.setRig(rig);
end

function protocol = createPulse(rig, nEpochs)
    protocol = io.github.symphony_das.protocols.Pulse();
    protocol.setRig(rig);
    protocol.numberOfAverages = uint16(nEpochs);
    protocol.interpulseInterval = 0;
end

function filepath = tempH5()
    filepath = fullfile(tempdir, ['symphony_e2e_' datestr(now, 'yyyymmddHHMMSSFFF') '_' num2str(randi(99999)) '.h5']);
end

function [persistor, filepath] = createRecordingFile()
    filepath = tempH5();
    cper = symphonyui.core.callNetStatic('Symphony.Core.H5EpochPersistor', 'Create', ...
        filepath, System.DateTimeOffset.Now, uint32(9));
    persistor = symphonyui.core.Persistor(cper);
end

function persistor = openFile(filepath)
    cper = symphonyui.core.createNetObj('Symphony.Core.H5EpochPersistor', filepath);
    persistor = symphonyui.core.Persistor(cper);
end

function deleteFileIfExists(filepath)
    if exist(filepath, 'file')
        try delete(filepath); catch, end
    end
    bakFile = [filepath '.bak'];
    if exist(bakFile, 'file')
        try delete(bakFile); catch, end
    end
end

function closeFigs()
    try close all; catch, end
end

%% ========== Tests ==========

function test1_viewOnly()
    [rig, controller] = createSimRig();
    protocol = createPulse(rig, 3);

    controller.runProtocol(protocol, []);

    assert_(controller.state == symphonyui.core.ControllerState.STOPPED, ...
        sprintf('Expected STOPPED state, got %s', char(controller.state)));
    closeFigs();
end

function test2_record()
    [persistor, filepath] = createRecordingFile();
    cleanup = onCleanup(@()deleteFileIfExists(filepath));

    source = persistor.addSource([], 'TestCell');
    persistor.beginEpochGroup(source, 'TestGroup');

    [rig, controller] = createSimRig();
    protocol = createPulse(rig, 3);
    controller.runProtocol(protocol, persistor);

    persistor.endEpochGroup();
    persistor.close();
    closeFigs();

    % Verify HDF5 structure exists
    info = h5info(filepath);
    assert_(~isempty(info.Groups), 'HDF5 file has no groups');

    % Reopen and verify basic hierarchy
    p2 = openFile(filepath);
    exp = p2.experiment;
    groups = exp.getEpochGroups();
    assert_(numel(groups) >= 1, 'Expected at least 1 epoch group');
    blocks = groups{1}.getEpochBlocks();
    assert_(numel(blocks) >= 1, 'Expected at least 1 epoch block');
    epochs = blocks{1}.getEpochs();
    assert_(numel(epochs) >= 1, 'Expected at least 1 epoch');
    p2.close();
end

function test3_dataIntegrity()
    [persistor, filepath] = createRecordingFile();
    cleanup = onCleanup(@()deleteFileIfExists(filepath));

    source = persistor.addSource([], 'TestCell');
    persistor.beginEpochGroup(source, 'DataTest');

    [rig, controller] = createSimRig();
    protocol = createPulse(rig, 3);
    controller.runProtocol(protocol, persistor);

    persistor.endEpochGroup();
    persistor.close();
    closeFigs();

    % Reopen and read response data
    p2 = openFile(filepath);
    exp = p2.experiment;
    groups = exp.getEpochGroups();
    blocks = groups{1}.getEpochBlocks();
    epochs = blocks{1}.getEpochs();

    assert_(numel(epochs) == 3, sprintf('Expected 3 epochs, got %d', numel(epochs)));

    for i = 1:numel(epochs)
        responses = epochs{i}.getResponses();
        assert_(numel(responses) >= 1, sprintf('Epoch %d has no responses', i));

        [q, u] = responses{1}.getData();
        assert_(~isempty(q), sprintf('Epoch %d response data is empty', i));
        assert_(all(isfinite(q)), sprintf('Epoch %d response contains NaN/Inf', i));
        assert_(~isempty(u), sprintf('Epoch %d response units is empty', i));

        % Pulse: preTime=50 + stimTime=500 + tailTime=50 = 600ms at 10kHz = 6000 samples
        expectedSamples = 6000;
        actualSamples = numel(q);
        assert_(abs(actualSamples - expectedSamples) <= 10, ...
            sprintf('Epoch %d: expected ~%d samples, got %d', i, expectedSamples, actualSamples));
    end

    p2.close();
end

function test4_pulseFamily()
    [persistor, filepath] = createRecordingFile();
    cleanup = onCleanup(@()deleteFileIfExists(filepath));

    source = persistor.addSource([], 'TestCell');
    persistor.beginEpochGroup(source, 'FamilyTest');

    [rig, controller] = createSimRig();
    protocol = io.github.symphony_das.protocols.PulseFamily();
    protocol.setRig(rig);
    protocol.pulsesInFamily = uint16(3);
    protocol.numberOfAverages = uint16(1);
    protocol.firstPulseSignal = 100;
    protocol.incrementPerPulse = 10;
    protocol.interpulseInterval = 0;
    controller.runProtocol(protocol, persistor);

    persistor.endEpochGroup();
    persistor.close();
    closeFigs();

    % Verify
    p2 = openFile(filepath);
    exp = p2.experiment;
    groups = exp.getEpochGroups();
    blocks = groups{1}.getEpochBlocks();
    epochs = blocks{1}.getEpochs();

    assert_(numel(epochs) == 3, sprintf('Expected 3 epochs, got %d', numel(epochs)));

    % Check pulseSignal parameters: 100, 110, 120
    expectedSignals = [100, 110, 120];
    for i = 1:numel(epochs)
        params = epochs{i}.protocolParameters;
        assert_(params.isKey('pulseSignal'), sprintf('Epoch %d missing pulseSignal parameter', i));
        actual = params('pulseSignal');
        assert_(abs(actual - expectedSignals(i)) < 0.01, ...
            sprintf('Epoch %d: expected pulseSignal=%.0f, got %.1f', i, expectedSignals(i), actual));
    end

    p2.close();
end

function test5_epochGroupLifecycle()
    [persistor, filepath] = createRecordingFile();
    cleanup = onCleanup(@()deleteFileIfExists(filepath));

    source = persistor.addSource([], 'TestCell');

    % Group 1: 2 epochs
    persistor.beginEpochGroup(source, 'Group1');
    [rig, controller] = createSimRig();
    protocol = createPulse(rig, 2);
    controller.runProtocol(protocol, persistor);
    persistor.endEpochGroup();
    closeFigs();

    % Group 2: 2 epochs
    persistor.beginEpochGroup(source, 'Group2');
    protocol2 = createPulse(rig, 2);
    controller.runProtocol(protocol2, persistor);
    persistor.endEpochGroup();
    closeFigs();

    persistor.close();

    % Verify
    p2 = openFile(filepath);
    exp = p2.experiment;
    groups = exp.getEpochGroups();

    assert_(numel(groups) == 2, sprintf('Expected 2 epoch groups, got %d', numel(groups)));
    assert_(strcmp(groups{1}.label, 'Group1'), sprintf('Expected Group1, got %s', groups{1}.label));
    assert_(strcmp(groups{2}.label, 'Group2'), sprintf('Expected Group2, got %s', groups{2}.label));

    blocks1 = groups{1}.getEpochBlocks();
    blocks2 = groups{2}.getEpochBlocks();
    assert_(numel(blocks1) >= 1, 'Group1 has no epoch blocks');
    assert_(numel(blocks2) >= 1, 'Group2 has no epoch blocks');

    epochs1 = blocks1{1}.getEpochs();
    epochs2 = blocks2{1}.getEpochs();
    assert_(numel(epochs1) == 2, sprintf('Group1 expected 2 epochs, got %d', numel(epochs1)));
    assert_(numel(epochs2) == 2, sprintf('Group2 expected 2 epochs, got %d', numel(epochs2)));

    p2.close();
end

function test6_propertyDescriptor()
    % Pure MATLAB test — no .NET required

    % Create descriptors with various value types, none with explicit type
    d1 = symphonyui.core.PropertyDescriptor('name', 'hello');
    d2 = symphonyui.core.PropertyDescriptor('amp', 100.0);
    d3 = symphonyui.core.PropertyDescriptor('flag', true);
    d4 = symphonyui.core.PropertyDescriptor('count', int32(5));
    d5 = symphonyui.core.PropertyDescriptor('items', {{'a', 'b', 'c'}});

    % One with explicit type
    d6 = symphonyui.core.PropertyDescriptor('sel', 'a', ...
        'type', symphonyui.core.PropertyType('char', 'row', {'a', 'b', 'c'}));

    descriptors = [d1, d2, d3, d4, d5, d6];

    for i = 1:numel(descriptors)
        s = saveobj(descriptors(i));

        assert_(isstruct(s.type), ...
            sprintf('Descriptor "%s": type is not a struct (class=%s)', s.name, class(s.type)));
        assert_(isfield(s.type, 'primitiveType'), ...
            sprintf('Descriptor "%s": type missing primitiveType', s.name));
        assert_(~isempty(s.type.primitiveType), ...
            sprintf('Descriptor "%s": primitiveType is empty', s.name));
        assert_(isfield(s.type, 'shape'), ...
            sprintf('Descriptor "%s": type missing shape', s.name));
        assert_(isfield(s.type, 'domain'), ...
            sprintf('Descriptor "%s": type missing domain', s.name));
    end

    % Verify the explicit-type descriptor preserved its domain
    s6 = saveobj(d6);
    assert_(numel(s6.type.domain) == 3, ...
        sprintf('Explicit type domain should have 3 items, got %d', numel(s6.type.domain)));

    % Verify round-trip through loadobj
    for i = 1:numel(descriptors)
        s = saveobj(descriptors(i));
        reloaded = symphonyui.core.PropertyDescriptor.loadobj(s);
        assert_(strcmp(reloaded.name, descriptors(i).name), ...
            sprintf('Round-trip name mismatch for "%s"', descriptors(i).name));
    end
end

function test7_streaming()
    opts = symphonyui.app.Options.getDefault();
    origEnabled = opts.streamingEnabled;
    origThreshold = opts.streamingThreshold;
    origChunks = opts.streamingMaxDisplayChunks;

    restoreOpts = onCleanup(@()restoreStreamingOpts(origEnabled, origThreshold, origChunks));

    % Enable streaming with low threshold
    opts.streamingEnabled = true;
    opts.streamingThreshold = 1;  % 1 second
    opts.streamingMaxDisplayChunks = 5;

    [rig, controller] = createSimRig();
    protocol = createPulse(rig, 1);
    protocol.stimTime = 2000;  % 2 seconds — exceeds threshold

    % View-only run (no file needed to verify streaming config propagation)
    controller.runProtocol(protocol, []);

    assert_(controller.state == symphonyui.core.ControllerState.STOPPED, ...
        sprintf('Expected STOPPED state, got %s', char(controller.state)));
    closeFigs();
end

function restoreStreamingOpts(enabled, threshold, chunks)
    try
        opts = symphonyui.app.Options.getDefault();
        opts.streamingEnabled = enabled;
        opts.streamingThreshold = threshold;
        opts.streamingMaxDisplayChunks = chunks;
    catch
    end
end

function test8_hdf5Integrity()
    [persistor, filepath] = createRecordingFile();
    cleanup = onCleanup(@()deleteFileIfExists(filepath));

    source = persistor.addSource([], 'TestCell');
    persistor.beginEpochGroup(source, 'IntegrityTest');

    [rig, controller] = createSimRig();
    protocol = io.github.symphony_das.protocols.PulseFamily();
    protocol.setRig(rig);
    protocol.pulsesInFamily = uint16(3);
    protocol.numberOfAverages = uint16(1);
    protocol.interpulseInterval = 0;
    controller.runProtocol(protocol, persistor);

    persistor.endEpochGroup();
    persistor.close();
    closeFigs();

    % Full hierarchy traversal — any exception = failure
    p2 = openFile(filepath);
    exp = p2.experiment;

    % Devices
    devices = exp.getDevices();
    assert_(numel(devices) >= 1, 'No devices in experiment');
    for i = 1:numel(devices)
        name = devices{i}.name; %#ok<NASGU>
    end

    % Sources
    sources = exp.getSources();
    assert_(numel(sources) >= 1, 'No sources in experiment');
    for i = 1:numel(sources)
        lbl = char(sources{i}.cobj.Label); %#ok<NASGU>
    end

    % Epoch groups → blocks → epochs → responses/stimuli/backgrounds
    groups = exp.getEpochGroups();
    for gi = 1:numel(groups)
        glabel = groups{gi}.label; %#ok<NASGU>
        blocks = groups{gi}.getEpochBlocks();
        for bi = 1:numel(blocks)
            pid = blocks{bi}.protocolId; %#ok<NASGU>
            pparams = blocks{bi}.protocolParameters; %#ok<NASGU>
            epochs = blocks{bi}.getEpochs();
            for ei = 1:numel(epochs)
                eparams = epochs{ei}.protocolParameters; %#ok<NASGU>

                responses = epochs{ei}.getResponses();
                for ri = 1:numel(responses)
                    [q, u] = responses{ri}.getData(); %#ok<ASGLU>
                    assert_(~isempty(q), 'Response data is empty during traversal');
                end

                stimuli = epochs{ei}.getStimuli();
                for si = 1:numel(stimuli)
                    stimId = stimuli{si}.stimulusId; %#ok<NASGU>
                end

                backgrounds = epochs{ei}.getBackgrounds();
                for bgi = 1:numel(backgrounds)
                    bgDev = backgrounds{bgi}.device; %#ok<NASGU>
                end
            end
        end
    end

    p2.close();

    % Raw HDF5 check
    info = h5info(filepath);
    assert_(~isempty(info), 'h5info returned empty');
end

function test9_migration()
    [persistor, filepath] = createRecordingFile();
    cleanup = onCleanup(@()deleteFileIfExists(filepath));

    source = persistor.addSource([], 'TestCell');
    persistor.beginEpochGroup(source, 'MigrationTest');

    [rig, controller] = createSimRig();
    protocol = createPulse(rig, 2);
    controller.runProtocol(protocol, persistor);

    persistor.endEpochGroup();
    persistor.close();
    closeFigs();

    % Run migration script in dry-run mode — should report no fixes needed
    % (since saveobj now always produces valid type structs)
    symphonyui.ui.fixH5ForSymphony2(filepath, 'DryRun', true);

    % Run actual migration — should be a no-op
    symphonyui.ui.fixH5ForSymphony2(filepath);

    % Verify file still readable
    p2 = openFile(filepath);
    exp = p2.experiment;
    groups = exp.getEpochGroups();
    assert_(numel(groups) >= 1, 'File unreadable after migration');
    p2.close();
end

function test10_performance()
    % File creation
    filepath = tempH5();
    cleanupFile = onCleanup(@()deleteFileIfExists(filepath));
    t = tic;
    cper = symphonyui.core.callNetStatic('Symphony.Core.H5EpochPersistor', 'Create', ...
        filepath, System.DateTimeOffset.Now, uint32(9));
    fileCreateTime = toc(t);
    cper.Close();
    deleteFileIfExists(filepath);
    assert_(fileCreateTime < 5.0, sprintf('File creation too slow: %.2fs', fileCreateTime));

    % Measurement creation (100x)
    t = tic;
    for i = 1:100
        symphonyui.core.createNetObj('Symphony.Core.Measurement', 1.0, 'V');
    end
    measTime = toc(t);
    assert_(measTime < 5.0, sprintf('100x Measurement too slow: %.2fs', measTime));

    % GetDataArray (100k samples)
    resp = symphonyui.core.createNetObj('Symphony.Core.Response');
    nSamples = 100000;
    quantities = rand(1, nSamples);
    cdata = symphonyui.core.callNetStatic('Symphony.Core.Measurement', 'FromArray', quantities, 'V');
    rate = symphonyui.core.createNetObj('Symphony.Core.Measurement', 10000.0, 'Hz');
    inputData = symphonyui.core.createNetObj('Symphony.Core.InputData', cdata, rate, System.DateTimeOffset.Now);
    resp.AppendData(inputData);

    t = tic;
    arr = resp.GetDataArray(); %#ok<NASGU>
    getDataTime = toc(t);
    assert_(getDataTime < 5.0, sprintf('GetDataArray too slow: %.2fs', getDataTime));

    % View-only acquisition run (3 epochs)
    [rig, controller] = createSimRig();
    protocol = createPulse(rig, 3);
    t = tic;
    controller.runProtocol(protocol, []);
    runTime = toc(t);
    closeFigs();
    assert_(runTime < 30.0, sprintf('3-epoch run too slow: %.2fs', runTime));

    fprintf('\n    Perf: file=%.3fs, 100xMeas=%.3fs, getData=%.3fs, 3epochs=%.2fs\n', ...
        fileCreateTime, measTime, getDataTime, runTime);
end
