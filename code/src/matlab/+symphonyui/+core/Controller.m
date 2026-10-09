classdef Controller < symphonyui.core.CoreObject
    % A Controller serves to run protocols and maintain the epoch queue.
    
    properties (SetObservable, SetAccess = private)
        state   % State of this controller (stopped, paused, running, etc.)
    end

    properties (SetAccess = private)
        rig                 % Rig assigned to this controller in setRig()
        currentProtocol     % Current running or paused protocol
        currentPersistor    % Current persistor or empty if there is no current persistor
    end

    properties (Access = private)
        epochQueueDuration  % Current duration of the epoch queue
        stopAfterEpoch = false  % When true, stop after the current epoch completes (saving it)
        stopRequestedTic = []   % tic of the first stop request of this run (stop watchdog)
        stopEscalation = 0      % 0 none, 1 core RequestStop forced, 2 DAQ stopped, 3 gave up
        stopEscalationTic = []
    end

    properties (Constant, Access = private)
        MAX_EPOCH_QUEUE_DURATION = seconds(3)   % Max allowable duration of the epoch queue
    end

    methods

        function obj = Controller()
            cobj = symphonyui.core.createNetObj('Symphony.Core.Controller');
            obj@symphonyui.core.CoreObject(cobj);

            obj.state = symphonyui.core.ControllerState.STOPPED;
        end

        function setRig(obj, rig)
            obj.cobj.DAQController = [];
            obj.cobj.Clock = [];
            obj.tryCore(@()obj.cobj.RemoveAllDevices());

            obj.cobj.DAQController = rig.daqController.cobj;
            obj.cobj.Clock = rig.daqController.cobj.Clock;

            devs = rig.devices;
            for i = 1:numel(devs)
                obj.tryCore(@()obj.cobj.AddDevice(devs{i}.cobj));
            end

            obj.rig = rig;
        end

        function runProtocol(obj, protocol, persistor)
            % Runs a protocol until the protocol indicates to stop. The persistor may be empty to indicate the protocol
            % epochs should not be persisted.
            
            if obj.state.isPaused()
                error('Controller is paused');
            end
            if obj.state.isRunning()
                return;
            end

            try
                obj.prepareRun(protocol, persistor);
                obj.run();
            catch x
                obj.completeRun();
                rethrow(x);
            end

            obj.completeRun();
        end

        function resume(obj)
            % Resumes a controller that's been paused while running a protocol.
            
            if ~obj.state.isPaused()
                error('Controller not paused');
            end

            if obj.state.isViewingPaused()
                obj.state = symphonyui.core.ControllerState.VIEWING;
            else
                obj.state = symphonyui.core.ControllerState.RECORDING;
            end

            try
                obj.run();
            catch x
                obj.completeRun();
                rethrow(x);
            end

            obj.completeRun();
        end

        function requestPause(obj)
            % Requests this controller to complete all currently buffered epochs and then pause.
            
            if ~obj.state.isRunning()
                return;
            end
            obj.state = symphonyui.core.ControllerState.PAUSING;
            obj.tryCore(@()obj.cobj.RequestPause());
        end

        function requestStop(obj)
            % Requests this controller stop and discard all incomplete buffered epochs.

            obj.noteStopRequest('requestStop');
            obj.stopAfterEpoch = false;
            if obj.state.isPaused()
                obj.state = symphonyui.core.ControllerState.STOPPED;
                obj.completeRun();
                return;
            end
            if ~obj.state.isRunning() && ~obj.state.isPausing()
                return;
            end
            obj.state = symphonyui.core.ControllerState.STOPPING;
            obj.tryCore(@()obj.cobj.RequestStop());
        end

        function requestStopAfterEpoch(obj)
            % Requests this controller stop after the current epoch completes
            % and saves it. The epoch finishes naturally and is persisted.

            obj.noteStopRequest('requestStopAfterEpoch');
            if obj.state.isPaused()
                obj.state = symphonyui.core.ControllerState.STOPPED;
                obj.completeRun();
                return;
            end
            if ~obj.state.isRunning() && ~obj.state.isPausing()
                return;
            end
            obj.stopAfterEpoch = true;
        end

        function requestStopAndSavePartial(obj)
            % Requests this controller stop immediately and save the current
            % in-progress epoch as partial data. The epoch is marked with
            % IsPartial = true before being persisted.
            %
            % This is useful for long streaming epochs where the user wants
            % to stop early but keep the data collected so far.

            obj.noteStopRequest('requestStopAndSavePartial');
            if obj.state.isPaused()
                obj.state = symphonyui.core.ControllerState.STOPPED;
                obj.completeRun();
                return;
            end
            if ~obj.state.isRunning() && ~obj.state.isPausing()
                return;
            end

            % Mark all in-progress epochs as partial and request immediate stop.
            % The C# Controller's discard loop checks IsPartial && ShouldBePersisted
            % and serializes the epoch instead of discarding it.
            try
                epochs = obj.cobj.IncompleteEpochs;
                if ~isempty(epochs)
                    n = epochs.Length;
                    % Mark the FIRST incomplete data epoch as partial.
                    % At high sample rates, multiple epochs can be queued:
                    % [data epoch (acquiring), interval, next data epoch, ...]
                    % The first data epoch is the one currently acquiring
                    % and the one the user wants to save.
                    marked = false;
                    for ei = 1:n
                        ep = epochs(ei);
                        try
                            hasData = ep.Responses.Count > 0;
                        catch
                            hasData = true;
                        end
                        if hasData
                            ep.IsPartial = true;
                            ep.ShouldBePersisted = true;
                            fprintf('Controller: marked epoch %d as partial (of %d incomplete)\n', ei, n);
                            marked = true;
                            break;  % Only save the first data epoch
                        end
                    end
                    if ~marked
                        fprintf('Controller: no data epoch found among %d incomplete epochs\n', n);
                    end
                end
            catch ex
                fprintf(2, 'Controller: failed to mark epoch as partial: %s\n', ex.message);
            end

            % Request immediate stop — the C# discard loop will save
            % partial epochs instead of discarding them.
            obj.stopAfterEpoch = false;
            if obj.state.isPaused()
                obj.state = symphonyui.core.ControllerState.STOPPED;
                obj.completeRun();
                return;
            end
            if ~obj.state.isRunning() && ~obj.state.isPausing()
                return;
            end
            obj.state = symphonyui.core.ControllerState.STOPPING;
            obj.tryCore(@()obj.cobj.RequestStop());
        end

        function d = get.epochQueueDuration(obj)
            cdur = obj.cobj.EpochQueueDuration;
            if cdur.IsNone()
                d = seconds(inf);
            else
                d = obj.durationFromTimeSpan(cdur.Item2);
            end
        end

    end

    methods (Access = protected)

        function prepareRun(obj, protocol, persistor)
            import symphonyui.core.ControllerState;

            obj.stopAfterEpoch = false;
            obj.stopRequestedTic = [];
            obj.stopEscalation = 0;
            obj.stopEscalationTic = [];
            obj.currentProtocol = protocol;
            obj.currentPersistor = persistor;

            if isempty(persistor)
                obj.state = ControllerState.VIEWING;
            else
                obj.state = ControllerState.RECORDING;
            end

            obj.clearEpochQueue();

            % Apply streaming settings from Options to the C# Controller.
            % When enabled, the C# ProcessLoop auto-creates a StreamingWriter
            % and sets Response.StreamingThreshold on each epoch's responses.
            %
            % Streaming is safe on all hardware when the ITC proxy is running
            % (ITCMM.dll is in a separate process, so HDF5 lock contention
            % can't block the ProcessLoop). Without the proxy, streaming is
            % disabled for Heka ITC hardware as a safety measure.
            try
                opts = symphonyui.app.Options.getDefault();

                if opts.streamingEnabled
                    thresholdSec = opts.streamingThreshold;
                    maxChunks = round(opts.streamingMaxDisplayChunks);
                    obj.cobj.StreamingThreshold = System.TimeSpan.FromSeconds(thresholdSec);
                    obj.cobj.StreamingMaxDisplayChunks = int32(maxChunks);
                else
                    obj.cobj.StreamingThreshold = [];
                end
            catch ex
                fprintf(2, 'Controller: failed to set streaming threshold: %s\n', ex.message);
            end

            protocol.prepareRun();

            % Ensure figure windows are rendered before acquisition starts.
            % On the first run, figure handlers create new windows that need
            % a drawnow to appear.
            drawnow;

            if ~isempty(persistor)
                map = protocol.getPropertyMap();
                keys = map.keys;
                for i = 1:numel(keys)
                    map(keys{i}) = obj.propertyValueFromValue(map(keys{i}));
                end

                % If out-of-process writer is connected, route beginEpochBlock
                % through it (the in-process file is closed during handoff).
                oopWriter = obj.cobj.OutOfProcessWriter;
                if ~isempty(oopWriter) && oopWriter.IsConnected
                    try
                        params = containers.Map(map.keys, map.values);
                        netParams = NET.createGeneric('System.Collections.Generic.Dictionary', ...
                            {'System.String', 'System.Object'});
                        paramKeys = params.keys;
                        for i = 1:numel(paramKeys)
                            netParams.Add(paramKeys{i}, params(paramKeys{i}));
                        end
                        oopWriter.BeginEpochBlock(class(protocol), netParams, System.DateTimeOffset.Now);
                    catch ex
                        fprintf(2, 'OOP BeginEpochBlock failed, falling back to in-process: %s\n', ex.message);
                        persistor.beginEpochBlock(class(protocol), map);
                    end
                else
                    persistor.beginEpochBlock(class(protocol), map);
                end
            end
        end

        function completeRun(obj)
            import symphonyui.core.ControllerState;

            protocol = obj.currentProtocol;
            persistor = obj.currentPersistor;

            if obj.state.isPausing()
                if isempty(persistor)
                    obj.state = ControllerState.VIEWING_PAUSED;
                else
                    obj.state = ControllerState.RECORDING_PAUSED;
                end
                return;
            end

            if ~isempty(persistor) && ~isempty(persistor.currentEpochBlock)
                % Route endEpochBlock through out-of-process writer if connected
                oopWriter = obj.cobj.OutOfProcessWriter;
                if ~isempty(oopWriter) && oopWriter.IsConnected
                    try
                        oopWriter.EndEpochBlock(System.DateTimeOffset.Now);
                    catch
                    end
                end
                try
                    persistor.endEpochBlock();
                catch ebEx %#ok<NASGU>
                    % Silently ignore — the epoch data was already saved.
                    % H5O.open errors occur when HDF5 handles become stale
                    % after partial saves or streaming operations. Log to
                    % debug file only (not command window).
                    try
                        fid = fopen(fullfile(getenv('USERPROFILE'), 'streaming_debug.log'), 'a');
                        if fid > 0
                            fprintf(fid, '%s | endEpochBlock error (non-fatal) | %s\n', datestr(now), ebEx.message);
                            fclose(fid);
                        end
                    catch
                    end
                end
            end

            try
                protocol.completeRun();
            catch x
                obj.state = ControllerState.STOPPED;
                obj.currentProtocol = [];
                obj.currentPersistor = [];
                rethrow(x);
            end

            obj.state = ControllerState.STOPPED;
            obj.currentProtocol = [];
            obj.currentPersistor = [];
        end

    end

    methods (Access = private)

        function run(obj)
            import symphonyui.core.util.NetListener;

            listeners = NetListener.empty(0, 1);

            listeners(end + 1) = NetListener(obj.cobj, 'Started', 'Symphony.Core.TimeStampedEventArgs', @(h,d)onStarted(obj,h,d));
            function onStarted(obj, ~, ~)
                if obj.state.isPausing()
                    obj.tryCore(@()obj.cobj.RequestPause());
                elseif obj.state.isStopping()
                    obj.tryCore(@()obj.cobj.RequestStop());
                end
            end

            listeners(end + 1) = NetListener(obj.cobj, 'Stopped', 'Symphony.Core.TimeStampedEventArgs', @(h,d)onStopped(obj,h,d));
            function onStopped(obj, ~, ~)
                if obj.state.isRunning()
                    obj.state = symphonyui.core.ControllerState.STOPPING;
                end
            end

            listeners(end + 1) = NetListener(obj.cobj.DAQController, 'StartedHardware', 'Symphony.Core.TimeStampedEventArgs', @(h,d)onDaqControllerStartedHardware(obj, h, d));
            function onDaqControllerStartedHardware(obj, ~, ~)
                try
                    obj.currentProtocol.controllerDidStartHardware();
                catch ex
                    % Log the actual error for diagnostics
                    try
                        fid = fopen(fullfile(getenv('USERPROFILE'), 'streaming_debug.log'), 'a');
                        if fid > 0
                            fprintf(fid, '%s | MATLAB onDaqControllerStartedHardware | %s\n%s\n', ...
                                datestr(now), ex.message, ex.getReport('extended'));
                            fclose(fid);
                        end
                    catch
                    end
                    obj.requestStop();
                    try
                        error(savejson('', ex, 'Compact', true));
                    catch
                        error('symphonyui:controller:hardwareStartError', '%s', ex.message);
                    end
                end
            end

            listeners(end + 1) = NetListener(obj.cobj, 'CompletedEpoch', 'Symphony.Core.TimeStampedEpochEventArgs', @(h,d)onCompletedEpoch(obj,h,d));
            function onCompletedEpoch(obj, ~, event)
                epoch = symphonyui.core.Epoch(event.Epoch);
                try
                    if epoch.isInterval()
                        obj.currentProtocol.completeInterval(epoch);
                    else
                        obj.currentProtocol.completeEpoch(epoch);
                    end
                catch ex
                    % Log the error but DO NOT stop acquisition for figure
                    % handler errors. Only stop for critical protocol errors.
                    % Treat ALL errors from completeEpoch/completeInterval as
                    % non-fatal. Figure handler errors should never crash
                    % acquisition. Log for diagnostics but continue.
                    try
                        fid = fopen(fullfile(getenv('USERPROFILE'), 'streaming_debug.log'), 'a');
                        if fid > 0
                            fprintf(fid, '%s | MATLAB onCompletedEpoch | %s\n%s\n', ...
                                datestr(now), ex.message, ex.getReport('extended'));
                            fclose(fid);
                        end
                    catch
                    end
                    fprintf(2, 'WARNING: CompletedEpoch callback error (acquisition continues): %s\n', ex.message);
                    if false  % Previously: critical errors stopped acquisition
                        try
                            error(savejson('', ex, 'Compact', true));
                        catch
                            error('symphonyui:controller:epochError', '%s', ex.message);
                        end
                    end
                end
                if obj.stopAfterEpoch || ~obj.currentProtocol.shouldContinueRun()
                    obj.stopAfterEpoch = false;
                    obj.requestStop();
                end
            end

            listeners(end + 1) = NetListener(obj.cobj, 'DiscardedEpoch', 'Symphony.Core.TimeStampedEpochEventArgs', @(h,d)onDiscardedEpoch(obj,h,d));
            function onDiscardedEpoch(obj, ~, ~)
                obj.requestStop();
            end

            try
                obj.process();
            catch x
                delete(listeners);
                rethrow(x);
            end

            delete(listeners);
        end

        function process(obj)
            if ~obj.currentProtocol.shouldContinueRun()
                return;
            end

            obj.preloadLoop();

            task = obj.startAsync(obj.currentPersistor);

            try
                obj.processLoop();
            catch x
                % Check if this is a non-fatal figure handler error that
                % was propagated through pause/drawnow's event processing.
                % Check if this is a callback/figure error propagated through
                % pause/drawnow. These should not crash acquisition.
                isCritical = contains(x.message, {'Unable to start', 'Unable to stop', ...
                    'Unable to push data', 'ITC_', 'HekaDAQ', 'hardware'});
                % Log the error for diagnostics
                try
                    fid = fopen(fullfile(getenv('USERPROFILE'), 'streaming_debug.log'), 'a');
                    if fid > 0
                        fprintf(fid, '%s | MATLAB processLoop error | %s\n%s\n', ...
                            datestr(now), x.message, x.getReport('extended'));
                        fclose(fid);
                    end
                catch
                end
                if ~isCritical
                    % Non-critical error (figure handler, etc.) — log but continue.
                    fprintf(2, 'WARNING: processLoop error (acquisition continues): %s\n', x.message);
                else
                    obj.requestStop();
                    while obj.cobj.IsRunning
                        pause(0.01);
                    end
                    obj.tryCore(@()obj.cobj.WaitForCompletedEpochTasks());
                    rethrow(x);
                end
            end

            % While the C# acquisition runs, periodically update streaming
            % figure handlers with the latest ring buffer data.
            streamingUpdateInterval = 1.0;  % seconds between display refreshes
            lastStreamUpdate = tic;
            streamUpdateCount = 0;
            while obj.cobj.IsRunning
                try
                    pause(0.01);
                catch pauseEx
                    % .NET callbacks during pause can throw figure errors.
                    % Log but continue acquisition.
                    fprintf(2, 'WARNING: Error during pause (acquisition continues): %s\n', pauseEx.message);
                end
                if obj.stopWatchdog(), break; end
                % Update streaming figures periodically
                if toc(lastStreamUpdate) >= streamingUpdateInterval
                    try
                        obj.updateStreamingFigures();
                        streamUpdateCount = streamUpdateCount + 1;
                    catch ex
                        fprintf(2, 'streaming update error: %s\n', ex.message);
                    end
                    lastStreamUpdate = tic;
                    try
                        drawnow limitrate;
                    catch
                    end
                end
            end
            if obj.stopEscalation < 3
                obj.tryCore(@()obj.cobj.WaitForCompletedEpochTasks());
            end

            while ~task.IsCompleted
                pause(0.01);
                if obj.stopWatchdog(), break; end
                if toc(lastStreamUpdate) >= streamingUpdateInterval
                    try obj.updateStreamingFigures(); catch, end
                    lastStreamUpdate = tic;
                    drawnow limitrate;
                    streamUpdateCount = streamUpdateCount + 1;
                end
            end
                        
            drawnow();
            if obj.stopEscalation >= 3
                error('symphonyui:controller:stopTimeout', ['Acquisition did not stop after the stop request: the core ' ...
                    'controller kept running even after its DAQ controller was stopped. The run was abandoned; the ' ...
                    'file is intact up to the last saved epoch. Close and restart Symphony before recording again. ' ...
                    'Details are in %s.'], fullfile(getenv('USERPROFILE'), 'streaming_debug.log'));
            end
            if task.IsFaulted
                % Log the actual .NET exception for diagnostics
                fullReport = '';
                try
                    fullReport = char(task.Exception.Flatten().ToString());
                    fprintf(2, '\n=== .NET Task Exception ===\n%s\n===========================\n\n', fullReport);
                    fid = fopen(fullfile(getenv('USERPROFILE'), 'streaming_debug.log'), 'a');
                    if fid > 0
                        fprintf(fid, '%s | MATLAB task.IsFaulted | %s\n', ...
                            datestr(now), fullReport);
                        fclose(fid);
                    end
                catch
                end
                try
                    report = symphonyui.core.util.netReport(task.Exception.Flatten());
                catch
                    report = fullReport;
                    if isempty(report)
                        report = 'Unknown .NET task fault';
                    end
                end
                isjson = ischar(report) && ~isempty(regexp(report, '^\s*(?:\[.+\])|(?:\{.+\})\s*$', 'once'));
                if isjson
                    try
                        ex = loadjson(report);
                        ex.stack = cell2mat(ex.stack{1})';
                        rethrow(ex);
                    catch rethrowEx
                        if strcmp(rethrowEx.identifier, '')
                            error('symphonyui:controller:taskFaulted', '%s', report);
                        else
                            rethrow(rethrowEx);
                        end
                    end
                else
                    error('symphonyui:controller:taskFaulted', '%s', report);
                end
            end
        end

        function preloadLoop(obj)
            while obj.shouldContinuePreloadingEpochs()
                obj.enqueueEpoch(obj.nextEpoch());
                obj.enqueueEpoch(obj.nextInterval());
                drawnow limitrate;
            end
        end

        function tf = shouldContinuePreloadingEpochs(obj)
            tf = obj.currentProtocol.shouldContinuePreloadingEpochs() ...
                && obj.epochQueueDuration < obj.MAX_EPOCH_QUEUE_DURATION ...
                && obj.state.isRunning();
        end

        function processLoop(obj)
            lastStreamTic = tic;
            while obj.shouldWaitToContinuePreparingEpochs()
                pause(0.01);
                obj.stopWatchdog();
                if toc(lastStreamTic) >= 0.5
                    try obj.updateStreamingFigures(); catch, end
                    lastStreamTic = tic;
                    drawnow limitrate;
                end
            end
            % While recording, flush the HDF5 file every few seconds so a crash
            % mid-run loses at most the last few seconds of epochs
            % (symphonyui.ui.FileCheckpoint.flushPersistor; it takes the
            % persistor's HDF5 lock, so it never races the writer thread).
            lastFlushTic = tic;
            flushEvery = 5;
            while obj.shouldContinuePreparingEpochs()
                obj.enqueueEpoch(obj.nextEpoch());
                obj.enqueueEpoch(obj.nextInterval());
                drawnow limitrate;
                while obj.shouldWaitToContinuePreparingEpochs()
                    pause(0.01);
                    obj.stopWatchdog();
                    if toc(lastStreamTic) >= 0.5
                        try obj.updateStreamingFigures(); catch, end
                        lastStreamTic = tic;
                        drawnow limitrate;
                    end
                    if ~isempty(obj.currentPersistor) && toc(lastFlushTic) >= flushEvery
                        lastFlushTic = tic;
                        if strcmp(symphonyui.ui.FileCheckpoint.getMode(), 'flush')
                            try
                                symphonyui.ui.FileCheckpoint.flushPersistor(obj.currentPersistor.cobj, 'periodic');
                            catch
                            end
                        end
                    end
                end
            end
        end

        function noteStopRequest(obj, how)
            % Stop watchdog bookkeeping: remember when the first stop was asked
            % for and leave a trace of the core state in streaming_debug.log.
            if isempty(obj.stopRequestedTic)
                obj.stopRequestedTic = tic;
            end
            obj.logStop('%s | state %s | %s', how, char(obj.state), obj.coreStatus());
        end

        function gaveUp = stopWatchdog(obj)
            % A stop request that the C# controller never completes used to
            % leave the app at "running" forever (2026-10-09, ContrastResponse
            % and StepPulseScale on Rig A). Once the grace period (20 s plus the
            % current epoch) has passed: force the core stop and clear the
            % queue; 10 s later stop the DAQ controller; 10 s later give up so
            % process() returns with an error and the app goes back to Stopped.
            gaveUp = obj.stopEscalation >= 3;
            if gaveUp || isempty(obj.stopRequestedTic), return; end
            try
                elapsed = toc(obj.stopRequestedTic);
                if elapsed < obj.stopGraceSeconds(), return; end
                switch obj.stopEscalation
                    case 0
                        obj.stopEscalation = 1;
                        obj.stopEscalationTic = tic;
                        obj.logStop('WATCHDOG stop not completed after %.0f s; forcing core RequestStop + ClearEpochQueue | %s', elapsed, obj.coreStatus());
                        fprintf(2, 'Stop watchdog: the run has not stopped after %.0f s; forcing the core to stop.\n', elapsed);
                        obj.stopAfterEpoch = false;
                        if ~obj.state.isStopping()
                            obj.state = symphonyui.core.ControllerState.STOPPING;
                        end
                        try obj.cobj.RequestStop(); catch, end
                        try obj.cobj.ClearEpochQueue(); catch, end
                    case 1
                        if toc(obj.stopEscalationTic) > 10
                            obj.stopEscalation = 2;
                            obj.stopEscalationTic = tic;
                            obj.logStop('WATCHDOG still running; stopping the DAQ controller | %s', obj.coreStatus());
                            fprintf(2, 'Stop watchdog: still running; stopping the DAQ controller.\n');
                            try obj.cobj.DAQController.RequestStop(); catch, end
                            try obj.cobj.DAQController.Stop(); catch, end
                        end
                    case 2
                        if toc(obj.stopEscalationTic) > 10
                            obj.stopEscalation = 3;
                            obj.logStop('WATCHDOG giving up | %s', obj.coreStatus());
                            fprintf(2, 'Stop watchdog: giving up; the run is abandoned.\n');
                            gaveUp = true;
                        end
                end
            catch ex
                fprintf(2, 'Stop watchdog error: %s\n', ex.message);
            end
        end

        function g = stopGraceSeconds(obj)
            g = 20;
            try
                ce = obj.cobj.CurrentEpoch;
                if ~isempty(ce)
                    g = g + double(ce.Duration.TotalSeconds);
                end
            catch
            end
        end

        function s = coreStatus(obj)
            s = '';
            try
                c = obj.cobj;
                ceTxt = 'none';
                ce = c.CurrentEpoch;
                if ~isempty(ce)
                    try
                        ceTxt = sprintf('complete=%d duration=%.1fs', ce.IsComplete, double(ce.Duration.TotalSeconds));
                    catch
                        ceTxt = 'present';
                    end
                end
                qd = 'n/a';
                try
                    cdur = c.EpochQueueDuration;
                    if cdur.IsNone(), qd = 'none'; else, qd = sprintf('%.1fs', double(cdur.Item2.TotalSeconds)); end
                catch
                end
                sw = 'none';
                try, if ~isempty(c.StreamingWriter), sw = sprintf('active=%d', c.StreamingWriter.IsActive); end, catch, end
                daq = 'n/a';
                try, daq = sprintf('running=%d', c.DAQController.IsRunning); catch, end
                nInc = 'n/a';
                try, nInc = sprintf('%d', c.IncompleteEpochs.Length); catch, end
                s = sprintf('core running=%d epoch[%s] queue=%s incomplete=%s streaming[%s] daq[%s]', ...
                    c.IsRunning, ceTxt, qd, nInc, sw, daq);
            catch ex
                s = ['status unavailable: ' ex.message];
            end
        end

        function logStop(~, varargin)
            try
                fid = fopen(fullfile(getenv('USERPROFILE'), 'streaming_debug.log'), 'a');
                if fid > 0
                    fprintf(fid, '%s | stop | %s\n', datestr(now), sprintf(varargin{:}));
                    fclose(fid);
                end
            catch
            end
        end

        function updateStreamingFigures(obj)
            % During acquisition, update figure handlers with live data.
            % Kept lightweight to avoid blocking the acquisition loop.
            if isempty(obj.currentProtocol)
                return;
            end
            try
                % Get the current epoch from the C# controller
                cEpoch = obj.cobj.CurrentEpoch;
                if isempty(cEpoch) || cEpoch.IsComplete
                    return;
                end

                epoch = symphonyui.core.Epoch(cEpoch);

                % Skip intervals
                if epoch.isInterval()
                    return;
                end

                % Update figures with current partial data
                obj.currentProtocol.updateStreamingFigures(epoch);
            catch ex
                fprintf(2, 'updateStreamingFigures error: %s\n', ex.message);
            end
        end

        function tf = shouldWaitToContinuePreparingEpochs(obj)
            tf = (obj.currentProtocol.shouldWaitToContinuePreparingEpochs() ...
                || obj.epochQueueDuration >= obj.MAX_EPOCH_QUEUE_DURATION) ...
                && obj.state.isRunning();
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.currentProtocol.shouldContinuePreparingEpochs() ...
                && obj.state.isRunning();
        end

        function e = nextEpoch(obj)
            e = symphonyui.core.Epoch(class(obj.currentProtocol));

            obj.currentProtocol.prepareEpoch(e);
            
            devices = obj.rig.getOutputDevices();
            for i = 1:numel(devices)
                d = devices{i};
                if ~e.hasStimulus(d) && ~e.hasBackground(d)
                    e.setBackground(d, d.background);
                end
            end
        end

        function e = nextInterval(obj)
            e = symphonyui.core.Epoch(class(obj.currentProtocol), true);
            e.shouldBePersisted = false;

            obj.currentProtocol.prepareInterval(e);
            
            devices = obj.rig.getOutputDevices();
            for i = 1:numel(devices)
                d = devices{i};
                if ~e.hasStimulus(d) && ~e.hasBackground(d)
                    e.setBackground(d, d.background);
                end
            end
        end

        function enqueueEpoch(obj, epoch)
            obj.tryCore(@()obj.cobj.EnqueueEpoch(epoch.cobj));
        end

        function clearEpochQueue(obj)
            obj.tryCore(@()obj.cobj.ClearEpochQueue());
        end

        function t = startAsync(obj, persistor)
            if isempty(persistor)
                cper = [];
            else
                cper = persistor.cobj;
            end
            t = obj.tryCoreWithReturn(@()obj.cobj.StartAsync(cper));
        end

    end

end
