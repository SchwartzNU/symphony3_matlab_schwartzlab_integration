classdef SymphonyApp < matlab.apps.AppBase
    % Standalone app: protocol/acquire and HDF document/Data Manager share one C#
    % AcquisitionHost (HdfEpochDocumentStore + H5EpochPersistor). Legacy MATLAB
    % Legacy MATLAB stack: Configure -> Devices; Configure -> Options uses symphonyui.ui.SymphonyOptionsDialog
    % (same symphonyui.app.Options / getpref as legacy OptionsPresenter).

    properties (Access = public)
        UIFigure matlab.ui.Figure
        fileMenu matlab.ui.container.Menu
        documentMenu matlab.ui.container.Menu
        AcquireMenu matlab.ui.container.Menu
        ConfigureMenu matlab.ui.container.Menu
        ModulesMenu matlab.ui.container.Menu
        PreviewMenu matlab.ui.container.Menu
        HelpMenu matlab.ui.container.Menu
        newFileMenu matlab.ui.container.Menu
        openFileMenu matlab.ui.container.Menu
        closeFileMenu matlab.ui.container.Menu
        exitMenu matlab.ui.container.Menu
        addSourceMenu matlab.ui.container.Menu
        beginEpochGroupMenu matlab.ui.container.Menu
        endEpochGroupMenu matlab.ui.container.Menu
        addNoteMenu matlab.ui.container.Menu
        acquireViewOnlyMenu matlab.ui.container.Menu
        acquireRecordMenu matlab.ui.container.Menu
        acquirePauseMenu matlab.ui.container.Menu
        acquireStopMenu matlab.ui.container.Menu
        acquireResetProtocolMenu matlab.ui.container.Menu
        acquireProtocolPresetsMenu matlab.ui.container.Menu
        initializeRigMenu matlab.ui.container.Menu
        configureDevicesMenu matlab.ui.container.Menu
        configureOptionsMenu matlab.ui.container.Menu
        rigBuilderMenu matlab.ui.container.Menu
        protocolBuilderMenu matlab.ui.container.Menu
        modulesRefreshMenu matlab.ui.container.Menu
        helpDocumentationMenu matlab.ui.container.Menu
        helpUserGroupMenu matlab.ui.container.Menu
        helpAboutMenu matlab.ui.container.Menu

        ProtocolDropDownLabel matlab.ui.control.Label
        protocolPopupMenu matlab.ui.control.DropDown

        protocolPanel matlab.ui.container.Panel
        previewView  % symphonyui.ui.PreviewView (separate window)

        viewOnlyButton matlab.ui.control.Button
        recordButton matlab.ui.control.Button
        pauseButton matlab.ui.control.Button
        stopAndSaveButton matlab.ui.control.Button
        stopAndDeleteButton matlab.ui.control.Button

        statusLabel matlab.ui.control.Label
    end

    properties (Access = private)
        % .NET host and lookup/cache state
        host
        protocolIdsByDisplayName
        isProgrammaticPropertyUpdate logical = false
        suppressViewOnlyWarning logical = false  % session-only: skip the View Only warning
        protocolPropertyGrid  % uigridlayout holding property rows
        protocolPropertyMeta cell = {}
        protocolPropertyControls cell = {}  % cell array of {label, valueControl} pairs
        % MATLAB-native rig & protocol management
        currentRig       % Live symphonyui.core.Rig instance (or [])
        currentProtocol  % Live symphonyui.core.Protocol instance (or [])
        controller       % symphonyui.core.Controller (MATLAB-side acquisition)
        % Lazy legacy context (Configure → Devices only; full Symphony UI presenters)
        legacyContext % symphonyui.ui.SymphonyLegacyContext
        % Host-backed Data Manager (HDF via C# AcquisitionHost — see HdfEpochDocumentStore)
        symphonyDataManager % symphonyui.ui.SymphonyDataManager
        % Flag to prevent Data Manager HDF5 reads during acquisition
        isAcquiring logical = false
        % Module management
        openModules cell = {}  % cell array of running symphonyui.ui.Module instances
        moduleMenuItems cell = {}  % cell array of dynamic module menu items
        discoveredModuleIds cell = {}  % class names discovered by populateModulesMenu
        % Cached MATLAB Persistor wrapper (avoids recreating & GC-closing the C# persistor)
        cachedPersistor  % symphonyui.core.Persistor or []
        % Session-scoped cache of per-protocol parameter maps, keyed by protocol class name
        % (e.g. 'edu.washington.riekelab.protocols.SingleSpot' → containers.Map of property values).
        % When the user switches protocols, the outgoing protocol's current property values
        % are captured here; when a protocol is re-selected later in the same session its
        % cached values are restored, so running-parameter tweaks are not lost on switch.
        % Cleared when SymphonyApp closes (session-scoped, not persisted to disk).
        protocolParameterCache  % containers.Map (string → containers.Map)
    end

    methods (Access = private)
        function startupFcn(app)
            app.addCodePaths();
            app.initHost();
            app.controller = symphonyui.core.Controller();
            app.protocolParameterCache = containers.Map('KeyType', 'char', 'ValueType', 'any');
            app.populateProtocolDropdown();
            app.populateModulesMenu();
            app.refreshProtocolPropertyGrid();
            app.refreshAcquireControls();

            % Run the Options startup file (if configured)
            app.runOptionsFile('startup');

            % Restore window position from previous session
            symphonyui.ui.ViewSettings.installAutoSave(app.UIFigure, 'SymphonyApp');

            % Show Initialize Rig dialog at startup (like the old Symphony)
            drawnow;  % ensure the main figure is rendered first
            app.configureInitializeRigSelected();
        end

        function addCodePaths(app) %#ok<MANU>
            % appDir = fileparts(mfilename('fullpath'));
            % addpath(genpath(fullfile(appDir, 'code', 'lib')));
            % addpath(fullfile(appDir, 'code', 'src', 'matlab'));
            % addpath(fullfile(appDir, 'code', 'matlab'));
            disp('Adding code paths...')
            addAppPaths();
        end

        function initHost(app)
            % appDir = fileparts(mfilename('fullpath'));
            % coreDir = fullfile(appDir, 'symphony-core');
            % 
            % % Load Core before Acquisition so MATLAB does not bind "Symphony" only to Acquisition
            % % (otherwise Symphony.Core.* fails with "Symphony has no ... named 'Core'").
            % if ispc
            %     NET.addAssembly(fullfile(coreDir, 'Symphony.Core', 'bin', 'Debug', 'net48', 'Symphony.Core.dll'));
            %     NET.addAssembly(fullfile(coreDir, 'Symphony.Acquisition', 'bin', 'Debug', 'net48', 'Symphony.Acquisition.dll'));
            % else
            %     NET.addAssembly(fullfile(coreDir, 'Symphony.Core', 'bin', 'Debug', 'net10.0', 'Symphony.Core.dll'));
            %     NET.addAssembly(fullfile(coreDir, 'Symphony.Acquisition', 'bin', 'Debug', 'net10.0', 'Symphony.Acquisition.dll'));
            % end

            dispatcher = symphonyui.core.createNetObj('Symphony.Acquisition.Bridge.StarterMatlabCommandDispatcher');
            app.host = symphonyui.core.callNetStatic('Symphony.Acquisition.HostFactory', 'CreateWithInProcessDispatcher', dispatcher);

            % Core (log4net) logging: configure it here, at startup, rather
            % than in the lazily created legacy context, so every session
            % leaves a log in Options -> loggingLogDirectory (~/.symphony/logs).
            logDir = './logs';
            try
                opts = symphonyui.app.Options.getDefault();
                logDir = char(opts.loggingLogDirectory);
                if ~isfolder(logDir)
                    mkdir(logDir);
                end
                Symphony.Core.Logging.ConfigureLogging(char(opts.loggingConfigurationFile), logDir);
                fprintf('Symphony core logging to %s\n', logDir);
            catch ex
                fprintf(2, 'Symphony core logging not configured: %s\n', ex.message);
            end

            initReq = symphonyui.core.createNetObj('Symphony.Acquisition.Contracts.HostInitRequest', ".", "", "", logDir);
            app.awaitTask(app.host.InitializeAsync(initReq));
            app.awaitTask(app.host.InitializeRigAsync("io.github.symphony.rigs.SimRig"));

            % Out-of-process HDF5 writer (experimental).
            % Enable with: setpref('SymphonyUI', 'outOfProcessWriter', true)
            % Disabled by default — the batch save queue + Data Manager
            % pause provides sufficient contention reduction for most setups.
            try
                useOopWriter = getpref('SymphonyUI', 'outOfProcessWriter', false);
                if useOopWriter
                    app.host.SetOutOfProcessWriterEnabled(true);
                    fprintf('initHost: Out-of-process HDF5 writer enabled (experimental)\n');
                end
            catch
            end
        end

        function paths = getSearchPaths(~)
            % Build the merged search paths: defaults + Options → Search Paths.
            sp = '';
            try
                opts = symphonyui.app.Options.getDefault();
                sp = opts.searchPath;
                if isa(sp, 'function_handle'), sp = sp(); end
                sp = char(sp);
            catch
                % Options not available — ignore
            end

            % Always include the built-in examples directory.
            appDir = fileparts(mfilename('fullpath'));
            defaultPaths = { ...
                fullfile(appDir, 'code', 'src', 'resources', 'examples') };

            % Only add the default paths if the Options paths are undefined
            if isempty(sp)
                paths = defaultPaths;
            else
                paths = strsplit(sp, ';');
                % paths = [defaultPaths, strsplit(sp, ';')];
            end
        end

        function populateProtocolDropdown(app)
            % Scan search paths for symphonyui.core.Protocol subclasses.
            protocols = symphonyui.ui.ProtocolScanner.discover(app.getSearchPaths());
            app.protocolIdsByDisplayName = containers.Map('KeyType', 'char', 'ValueType', 'char');

            n = numel(protocols);
            items = cell(1, n + 1);
            items{1} = '(None)';

            for i = 1:n
                displayName = protocols(i).displayName;
                protocolId = protocols(i).id;
                items{i + 1} = displayName;
                app.protocolIdsByDisplayName(displayName) = protocolId;
            end

            app.protocolPopupMenu.Items = items;
            app.protocolPopupMenu.Value = '(None)';
        end

        function protocolPopupMenuValueChanged(app, ~)
            selectedName = app.protocolPopupMenu.Value;
            try
                % Dispose previous protocol — but first, snapshot its current
                % property values into the session cache so that if the user
                % returns to this protocol later, they don't have to redo any
                % tweaks they made. Keyed by the protocol's class name.
                %
                % We cache only WRITEABLE public properties (skipping read-only,
                % Dependent, Constant, and non-public-set properties). Caching
                % a computed property is wasted work — `setProperty` would refuse
                % to restore it anyway.
                if ~isempty(app.currentProtocol)
                    try
                        outgoingId = class(app.currentProtocol);
                        app.protocolParameterCache(outgoingId) = ...
                            symphonyui.ui.captureWriteableProperties(app.currentProtocol);
                    catch cacheEx
                        % Never let a caching failure disrupt the switch.
                        fprintf(2, 'WARNING: could not cache parameters for %s: %s\n', ...
                            class(app.currentProtocol), cacheEx.message);
                    end
                    try
                        app.currentProtocol.close();
                    catch
                    end
                    app.currentProtocol = [];
                end

                if strcmp(selectedName, '(None)')
                    % Also notify the C# host (for acquire state tracking)
                    app.awaitTask(app.host.SelectProtocolAsync([]));
                else
                    if ~app.protocolIdsByDisplayName.isKey(selectedName)
                        error('Selected protocol was not found.');
                    end
                    protocolId = app.protocolIdsByDisplayName(selectedName);

                    % Create the MATLAB protocol instance
                    ctorFcn = str2func(protocolId);
                    app.currentProtocol = ctorFcn();

                    % Assign the rig so device properties populate
                    if ~isempty(app.currentRig)
                        app.currentProtocol.setRig(app.currentRig);
                    end

                    % Restore cached parameters from earlier in this session
                    % (if any). This is a direct per-property assignment rather
                    % than `setPropertyMap`, because `setPropertyMap` runs each
                    % value through `setProperty` which requires a non-empty
                    % PropertyType companion (`*Type`) — many valid properties
                    % don't have one, and that unnecessarily blocks the restore.
                    % Each assignment is tried independently so a single bad
                    % property (stale device name, renamed field, tightened type)
                    % cannot abort the rest.
                    if isKey(app.protocolParameterCache, protocolId)
                        cached = app.protocolParameterCache(protocolId);
                        failures = symphonyui.ui.restoreWriteableProperties( ...
                            app.currentProtocol, cached);
                        if ~isempty(failures)
                            fprintf(2, ['WARNING: %d cached parameter(s) for %s ' ...
                                'could not be restored:\n'], numel(failures), protocolId);
                            for f = 1:numel(failures)
                                fprintf(2, '  - %s: %s\n', failures(f).name, ...
                                    failures(f).message);
                            end
                        end
                    end

                    % Notify the C# host so acquire controls update
                    try
                        app.awaitTask(app.host.SelectProtocolAsync(protocolId));
                    catch
                        % Host may not know this protocol — that's fine,
                        % MATLAB-side management takes precedence.
                    end
                end

                app.refreshProtocolPropertyGrid();
                app.refreshAcquireControls();
                app.refreshPreview();
            catch ex
                app.showError(ex, 'Protocol Error');
            end
        end

        function onWindowKeyPress(app, event)
            mods = {};
            try
                mods = event.Modifier;
            catch
            end
            if any(strcmpi(mods, 'control')) || any(strcmpi(mods, 'command'))
                switch lower(event.Key)
                    case 'n'
                        app.fileNewSelected();
                    case 'o'
                        app.fileOpenSelected();
                    case 't'
                        app.documentAddNoteSelected();
                    case 'b'
                        app.documentBeginEpochGroupSelected();
                    case 'e'
                        app.documentEndEpochGroupSelected();
                end
            end
        end

        function onWindowResize(app)
            % Reflow the manually-positioned main-window controls so the
            % protocol panel (and the parameter list inside it) grows with
            % the window. Buttons stay bottom-anchored at their fixed
            % positions; the dropdown row stays top-anchored, full width.
            if isempty(app.UIFigure) || ~isvalid(app.UIFigure)
                return;
            end
            p = app.UIFigure.Position;
            W = p(3);
            H = p(4);
            m = 10;              % outer margin
            topH = 22;           % dropdown/label row height
            panelBottom = 106;   % keep clear of the button row (y 52..97)
            if ~isempty(app.ProtocolDropDownLabel) && isvalid(app.ProtocolDropDownLabel)
                app.ProtocolDropDownLabel.Position = [5, H - topH - 2, 45, topH];
            end
            if ~isempty(app.protocolPopupMenu) && isvalid(app.protocolPopupMenu)
                app.protocolPopupMenu.Position = [68, H - topH - 2, max(80, W - 68 - m), topH];
            end
            if ~isempty(app.statusLabel) && isvalid(app.statusLabel)
                app.statusLabel.Position = [m, 20, max(80, W - 2*m), topH];
            end
            if ~isempty(app.protocolPanel) && isvalid(app.protocolPanel)
                panelTop = H - topH - 6;
                app.protocolPanel.Position = [m, panelBottom, ...
                    max(120, W - 2*m), max(60, panelTop - panelBottom)];
            end
        end

        function ensureLegacyContext(app)
            if isempty(app.legacyContext)
                appDir = fileparts(mfilename('fullpath'));
                app.legacyContext = symphonyui.ui.SymphonyLegacyContext(appDir);
            end
        end

        function fileNewSelected(app, ~)
            try
                result = symphonyui.ui.NewFileDialog.showBlocking(app.UIFigure, app.host, app.getSearchPaths());
                if isempty(result)
                    return;
                end
                app.showDataManager('Created');
                app.persistRigDeviceResources();
                % Pass experiment description ID to the Data Manager so it
                % can populate the Properties tab from the MATLAB description.
                if isstruct(result) && isfield(result, 'experimentDescriptionId') ...
                        && ~isempty(result.experimentDescriptionId) ...
                        && ~isempty(app.symphonyDataManager)
                    app.symphonyDataManager.setExperimentDescriptionId(result.experimentDescriptionId);
                end
                app.refreshAcquireControls();
            catch ex
                fprintf(2, 'fileNewSelected ERROR: %s\n', ex.message);
                app.showError(ex, 'New File Error');
            end
        end

        function fileOpenSelected(app, ~)
            try
                % Use the default file location from Options as the starting directory
                defaultDir = '';
                try
                    opts = symphonyui.app.Options.getDefault();
                    dl = opts.fileDefaultLocation;
                    if isa(dl, 'function_handle'), dl = dl(); end
                    dl = char(dl);
                    if isfolder(dl), defaultDir = dl; end
                catch
                end
                if ~isempty(defaultDir)
                    startPath = fullfile(defaultDir, '*.h5');
                else
                    startPath = '*.h5';
                end
                [filename, pathname] = uigetfile({'*.h5;*.hdf5', 'Symphony Files (*.h5, *.hdf5)'; '*.*', 'All Files'}, 'Open File', startPath);
                if isequal(filename, 0) || isequal(pathname, 0)
                    return;
                end
                app.awaitTask(app.host.OpenFileAsync(fullfile(pathname, filename)));
                symphonyui.ui.FileCheckpoint.setPath(fullfile(pathname, filename));
                app.showDataManager('Opened');
                app.refreshAcquireControls();
            catch ex
                app.showError(ex, 'Open File Error');
            end
        end

        function fileCloseSelected(app, ~)
            try
                % Clear cached persistor BEFORE closing the file so the
                % wrapper's delete() doesn't double-close.
                app.cachedPersistor = [];
                if logical(app.awaitTaskWithResult(app.host.HasOpenFileAsync()))
                    app.runFileCleanupFunction();
                    app.awaitTask(app.host.CloseFileAsync());
                    symphonyui.ui.FileCheckpoint.setPath('');
                end
                app.closeDataManager();
                app.refreshAcquireControls();
            catch ex
                app.showError(ex, 'Close File Error');
            end
        end

        function showDataManager(app, action)
            if nargin < 2
                action = 'Opened';
            end
            if isempty(app.symphonyDataManager)
                app.symphonyDataManager = symphonyui.ui.SymphonyDataManager( ...
                    app.host, app.UIFigure, @app.refreshAcquireControls, @(varargin)app.configureDevicesFromDataManager());
            end
            app.symphonyDataManager.show(action);
        end

        function refreshDataManagerView(app, fullRebuild)
            if nargin < 2, fullRebuild = true; end
            % During acquisition, skip full rebuilds but allow incremental
            % updates. With separate HDF5 libraries (hdf5_symphony.dll),
            % MATLAB reads don't conflict with C# writes.
            if app.isAcquiring && fullRebuild
                return;
            end
            if ~isempty(app.symphonyDataManager)
                try
                    app.symphonyDataManager.refresh(fullRebuild);
                catch
                end
            end
        end

        function pauseDataManagerDuringAcquisition(app)
            % Disable Data Manager interactions that would read HDF5.
            if ~isempty(app.symphonyDataManager) && isvalid(app.symphonyDataManager)
                try
                    app.symphonyDataManager.setAcquisitionMode(true);
                catch
                end
            end
        end

        function resumeDataManagerAfterAcquisition(app)
            % Re-enable Data Manager after acquisition completes.
            if ~isempty(app.symphonyDataManager) && isvalid(app.symphonyDataManager)
                try
                    app.symphonyDataManager.setAcquisitionMode(false);
                catch
                end
            end
        end

        function closeDataManager(app)
            if ~isempty(app.symphonyDataManager)
                try
                    app.symphonyDataManager.close();
                catch
                end
            end
        end

        function fileExitSelected(app, ~)
            delete(app);
        end

        function documentAddSourceSelected(app, ~)
            try
                if ~logical(app.awaitTaskWithResult(app.host.HasOpenFileAsync()))
                    uialert(app.UIFigure, 'Open or create a data file first.', 'Document');
                    return;
                end
                result = symphonyui.ui.AddSourceDialog.showBlocking(app.UIFigure, app.host, app.getSearchPaths());
                if isempty(result)
                    return;
                end
                app.checkpointFile('source');   % flush the new source to disk
                app.refreshDataManagerView();
                app.refreshAcquireControls();
            catch ex
                app.showError(ex, 'Add Source Error');
            end
        end

        function documentBeginEpochGroupSelected(app, ~)
            try
                hasFile = logical(app.awaitTaskWithResult(app.host.HasOpenFileAsync()));
                if ~hasFile
                    uialert(app.UIFigure, 'Open or create a data file first.', 'Document');
                    return;
                end
                sp = app.getSearchPaths();
                result = symphonyui.ui.BeginEpochGroupDialog.showBlocking( ...
                    app.UIFigure, app.host, sp);
                if isempty(result)
                    return;
                end
                app.checkpointFile('epochGroup');   % flush the new group to disk
                app.refreshDataManagerView();  % full rebuild to show new epoch group
                app.hasOpenEpochGroup(true);   % force cache refresh
                app.refreshAcquireControls();
            catch ex
                app.showError(ex, 'Begin Epoch Group Error');
            end
        end

        function documentEndEpochGroupSelected(app, ~)
            try
                if ~logical(app.awaitTaskWithResult(app.host.HasOpenFileAsync()))
                    uialert(app.UIFigure, 'Open or create a data file first.', 'Document');
                    return;
                end
                try
                    app.awaitTask(app.host.EndEpochGroupAsync());
                catch egEx
                    % EndEpochGroup can fail with H5O.open errors on stale
                    % handles. Log but continue — the data is already saved.
                    fprintf(2, 'WARNING: EndEpochGroup had errors (data is safe): %s\n', egEx.message);
                    % Force the C# persistor to clear its epoch group state
                    try
                        cper = app.host.GetPersistor();
                        if ~isempty(cper) && ~isempty(cper.CurrentEpochGroup)
                            % Try again — the C# side may have already handled it
                            try
                                cper.EndEpochGroup();
                            catch
                                % Force clear by closing and reopening
                            end
                        end
                    catch
                    end
                end
                checkpointed = app.checkpointFile('epochGroup');
                app.refreshDataManagerView(checkpointed);
                app.hasOpenEpochGroup(true);   % force cache refresh
                app.refreshAcquireControls();
            catch ex
                app.showError(ex, 'End Epoch Group Error');
            end
        end

        function documentAddNoteSelected(app, ~)
            try
                if ~logical(app.awaitTaskWithResult(app.host.HasOpenFileAsync()))
                    uialert(app.UIFigure, 'Open or create a data file first.', 'Document');
                    return;
                end
                answer = inputdlg('Note text:', 'Add Note to Experiment', [4 60], {''});
                if isempty(answer)
                    return;
                end
                app.awaitTask(app.host.AddNoteToExperimentAsync(answer{1}));
                app.refreshDataManagerView();
                app.refreshAcquireControls();
            catch ex
                app.showError(ex, 'Add Note Error');
            end
        end

        function acquireViewOnlySelected(app, ~)
            app.viewOnlyButtonPushed([]);
        end

        function acquireRecordSelected(app, ~)
            app.recordButtonPushed([]);
        end

        function acquirePauseSelected(app, ~)
            app.pauseButtonPushed([]);
        end

        function acquireStopSelected(app, ~)
            app.stopAndDeleteButtonPushed([]);
        end

        function acquireResetProtocolSelected(app, ~)
            try
                app.awaitTask(app.host.ResetProtocolAsync());
                app.refreshProtocolPropertyGrid();
                app.refreshAcquireControls();
            catch ex
                app.showError(ex, 'Reset Protocol Error');
            end
        end

        function acquireProtocolPresetsSelected(app, ~)
            try
                getProtocol = @() app.currentProtocol;
                applyPreset = @(protocolId, propMap) app.applyProtocolPreset(protocolId, propMap);
                viewOnlyFcn = @() app.viewOnlyButtonPushed([]);
                recordFcn = @() app.recordButtonPushed([]);
                canRecordFcn = @() app.hasOpenEpochGroup();
                symphonyui.ui.ProtocolPresetsDialog.show( ...
                    app.UIFigure, getProtocol, applyPreset, viewOnlyFcn, recordFcn, canRecordFcn);
            catch ex
                app.showError(ex, 'Protocol Presets Error');
            end
        end

        function applyProtocolPreset(app, protocolId, propertyMap)
            % Select the protocol matching protocolId if it's different
            if isempty(app.currentProtocol) || ~strcmp(class(app.currentProtocol), protocolId)
                % Find and select the protocol in the dropdown
                if isKey(app.protocolIdsByDisplayName, protocolId)
                    % Already keyed by display name — search by id
                end
                allIds = values(app.protocolIdsByDisplayName);
                allNames = keys(app.protocolIdsByDisplayName);
                idx = find(strcmp(allIds, protocolId), 1);
                if ~isempty(idx)
                    app.protocolPopupMenu.Value = allNames{idx};
                    app.protocolPopupMenuValueChanged([]);
                end
            end

            % Apply the property map to the current protocol
            if ~isempty(app.currentProtocol) && ~isempty(propertyMap)
                propKeys = propertyMap.keys;
                for i = 1:numel(propKeys)
                    k = propKeys{i};
                    try
                        app.currentProtocol.(k) = propertyMap(k);
                    catch
                        % Skip properties that don't exist on this protocol
                    end
                end
            end

            app.refreshProtocolPropertyGrid();
            app.refreshAcquireControls();
            app.refreshPreview();
        end

        function configureInitializeRigSelected(app, ~)
            try
                % Re-initializing inside a running session means closing the previous
                % rig's native devices (LightCrafter USB library, NI-DAQmx, MultiClamp
                % telegraph) and opening them again in the same process. On 2026-10-09
                % that killed MATLAB with a heap-corruption fault right after the old
                % LightCrafter connection was closed. Prefer a fresh MATLAB.
                if ~isempty(app.currentRig)
                    choice = uiconfirm(app.UIFigure, ...
                        ['A rig is already initialized in this session. Re-initializing in the ' ...
                         'same MATLAB process has crashed MATLAB (native device libraries are ' ...
                         'closed and reopened in place). Close Symphony and start it again instead.'], ...
                        'Initialize Rig', 'Options', {'Cancel', 'Re-initialize anyway'}, ...
                        'DefaultOption', 1, 'CancelOption', 1, 'Icon', 'warning');
                    if ~strcmp(choice, 'Re-initialize anyway')
                        return;
                    end
                end
                % Close the previous rig BEFORE creating the new one.
                % MultiClampDevice.Dispose() releases the COM telegraph
                % connection to MultiClamp Commander. If we don't close
                % first, the new rig's MultiClampDevice constructor may
                % fail to detect Commander (stale COM handle).
                if ~isempty(app.currentRig)
                    try app.currentRig.close(); catch, end
                end

                result = symphonyui.ui.InitializeRigDialog.showBlocking( ...
                    app.UIFigure, app.host, app.getSearchPaths());
                if isempty(result)
                    return;
                end
                app.currentRig = result;  % Rig object returned by dialog

                % Connect the rig to the MATLAB-side controller
                app.controller.setRig(app.currentRig);

                % Close old figure handlers — they hold stale device
                % references from the previous rig. They will be recreated
                % with the new rig's devices on the next protocol run.
                app.closeFigureHandlers();

                % Re-assign rig to current protocol if one is selected
                if ~isempty(app.currentProtocol)
                    app.currentProtocol.setRig(app.currentRig);
                end

                app.populateProtocolDropdown();
                app.refreshProtocolPropertyGrid();
                app.refreshAcquireControls();

                % Close preloaded (hidden) modules — they hold stale rig refs
                hiddenMods = {};
                for i = 1:numel(app.openModules)
                    try
                        if isvalid(app.openModules{i}) && ...
                           strcmp(app.openModules{i}.getFigureHandle().Visible, 'off')
                            hiddenMods{end+1} = app.openModules{i}; %#ok<AGROW>
                        end
                    catch
                    end
                end
                for i = 1:numel(hiddenMods)
                    try hiddenMods{i}.stop(); catch, end
                end

                % Preload modules in background after a short delay so the
                % main window finishes rendering first.
                existingTimers = timerfind('Tag', 'ModulePreloader');
                if ~isempty(existingTimers)
                    stop(existingTimers);
                    delete(existingTimers);
                end
                % The callback is guarded (SymphonyApp.preloadModulesIfValid):
                % closing Symphony within the delay otherwise fires it on a
                % deleted app ("Invalid or deleted object" in TimerFcn).
                t = timer('TimerFcn', @(~,~)SymphonyApp.preloadModulesIfValid(app), ...
                    'StartDelay', 1, 'ExecutionMode', 'singleShot', ...
                    'Name', 'SymphonyModulePreloader', 'Tag', 'ModulePreloader', ...
                    'StopFcn', @(src,~)delete(src));
                start(t);
            catch ex
                app.showError(ex, 'Initialize Rig Error');
            end
        end

        function configureDevicesFromDataManager(app)
            % Invoked from symphonyui.ui.SymphonyDataManager (no source/event args).
            app.configureDevicesSelected();
        end

        function configureDevicesSelected(app, ~)
            try
                if isempty(app.currentRig)
                    uialert(app.UIFigure, 'No rig initialized. Initialize a rig first.', 'Configure Devices');
                    return;
                end
                % Create a lightweight adapter that provides getDevices()
                % from the current rig (no legacy context needed).
                adapter = struct('getDevices', @(varargin) app.currentRig.getDevices());
                symphonyui.ui.DevicesDialog.showBlocking(app.UIFigure, adapter);
            catch ex
                app.showError(ex, 'Configure Devices');
            end
        end

        function configureOptionsSelected(app, ~)
            try
                symphonyui.ui.SymphonyOptionsDialog.showBlocking(app.UIFigure);
            catch ex
                app.showError(ex, 'Options');
            end
        end

        function configureRigBuilderSelected(app, ~)
            try
                symphonyui.ui.RigBuilderDialog.showBlocking(app.UIFigure);
            catch ex
                app.showError(ex, 'Rig Builder');
            end
        end

        function configureProtocolBuilderSelected(app, ~)
            try
                symphonyui.ui.ProtocolBuilderDialog.showBlocking(app.UIFigure);
            catch ex
                app.showError(ex, 'Protocol Builder');
            end
        end

        function previewShowSelected(app, ~)
            try
                if isempty(app.previewView) || ~isvalid(app.previewView)
                    app.previewView = symphonyui.ui.PreviewView(app.UIFigure);
                end
                app.previewView.show();
                app.refreshPreview();
            catch ex
                app.showError(ex, 'Preview');
            end
        end

        function tf = hasOpenEpochGroup(app, forceRefresh)
            %HASOPENEPOCHGROUP  True if the C# host reports an open epoch group.
            %   Cached to reduce HDF5 reads. Pass forceRefresh=true to bypass cache.
            persistent cachedValue cachedTic;
            if isempty(cachedValue), cachedValue = false; end
            if nargin < 2, forceRefresh = false; end
            tf = false;
            if app.isAcquiring
                tf = true;
                return;
            end
            % Return cached value if checked recently (unless forced)
            if ~forceRefresh && ~isempty(cachedTic) && toc(cachedTic) < 0.5
                tf = cachedValue;
                return;
            end
            try
                expState = app.awaitTaskWithResult(app.host.GetExperimentStateAsync());
                tf = logical(expState.HasEpochGroup);
            catch
            end
            cachedValue = tf;
            cachedTic = tic;
        end

        function refreshPreview(app)
            % Update the preview window if it is open and visible.
            if isempty(app.previewView) || ~app.previewView.isReady()
                return;
            end
            if ~app.previewView.isVisible()
                return;
            end
            try
                app.previewView.updateFromProtocol(app.currentProtocol);
            catch ex
                fprintf(2, 'refreshPreview: %s\n', ex.message);
            end
        end

        function modulesRefreshSelected(app, ~)
            app.populateModulesMenu();
        end

        function populateModulesMenu(app)
            % Remove previously created dynamic module menu items
            for i = 1:numel(app.moduleMenuItems)
                try delete(app.moduleMenuItems{i}); catch, end
            end
            app.moduleMenuItems = {};

            % Discover modules from search paths
            try
                modules = symphonyui.ui.ProtocolScanner.discoverModules(app.getSearchPaths());
            catch ex
                fprintf(2, 'Module discovery failed: %s\n', ex.message);
                modules = struct('id', {}, 'displayName', {});
            end

            if isempty(modules)
                app.discoveredModuleIds = {};
                m = uimenu(app.ModulesMenu, 'Text', '(no modules available)', 'Enable', 'off');
                app.moduleMenuItems{end+1} = m;
                return;
            end

            % Store discovered IDs for preloading
            app.discoveredModuleIds = {modules.id};

            % Add a separator and then one menu item per module
            for i = 1:numel(modules)
                modId = modules(i).id;
                modName = modules(i).displayName;
                m = uimenu(app.ModulesMenu, ...
                    'Text', modName, ...
                    'MenuSelectedFcn', @(~,~)app.launchModule(modId));
                app.moduleMenuItems{end+1} = m;
            end
        end

        function launchModule(app, className)
            % Check if the module is already open — if so, bring it to front
            for i = 1:numel(app.openModules)
                mod = app.openModules{i};
                if isvalid(mod) && strcmp(class(mod), className)
                    mod.show();
                    return;
                end
            end

            try
                constructor = str2func(className);
                mod = constructor();

                % Inject a lightweight configuration adapter backed by the current rig
                if ~isempty(app.currentRig)
                    configAdapter = symphonyui.ui.ModuleConfigurationAdapter(app.currentRig);
                    mod.setConfigurationService(configAdapter);
                end
                mod.setAcquisitionService(symphonyui.ui.ModuleAcquisitionAdapter(app));

                mod.go();
                app.openModules{end+1} = mod;
                addlistener(mod, 'Stopped', @(src,~)app.onModuleStopped(src));
            catch ex
                app.showError(ex, 'Module Error');
            end
        end

        function onModuleStopped(app, mod)
            % Remove the module from the open list, guarding against
            % already-deleted handles.
            keep = true(size(app.openModules));
            for i = 1:numel(app.openModules)
                try
                    if ~isvalid(app.openModules{i}) || app.openModules{i} == mod
                        keep(i) = false;
                    end
                catch
                    keep(i) = false;
                end
            end
            try delete(mod); catch, end
            app.openModules = app.openModules(keep);
        end

        function preloadModules(app)
            %PRELOADMODULES  Create and initialize all discovered modules in
            %   the background so they open instantly when the user clicks them.
            %   Each module's uifigure and UI components are built and willGo/bind
            %   are executed, but the figure stays hidden (Visible='off').
            %   launchModule() will find them in openModules and just call show().
            for i = 1:numel(app.discoveredModuleIds)
                className = app.discoveredModuleIds{i};

                % Skip if already open
                alreadyOpen = false;
                for j = 1:numel(app.openModules)
                    try
                        if isvalid(app.openModules{j}) && strcmp(class(app.openModules{j}), className)
                            alreadyOpen = true;
                            break;
                        end
                    catch
                    end
                end
                if alreadyOpen, continue; end

                try
                    constructor = str2func(className);
                    mod = constructor();  % creates uifigure + createUi (hidden)

                    if ~isempty(app.currentRig)
                        configAdapter = symphonyui.ui.ModuleConfigurationAdapter(app.currentRig);
                        mod.setConfigurationService(configAdapter);
                    end
                    mod.setAcquisitionService(symphonyui.ui.ModuleAcquisitionAdapter(app));

                    mod.preload();  % willGo + bind, stays hidden
                    app.openModules{end+1} = mod;
                    addlistener(mod, 'Stopped', @(src,~)app.onModuleStopped(src));
                catch ex
                    fprintf(2, 'Module preload skipped (%s): %s\n', className, ex.message);
                end

                drawnow limitrate;  % yield to UI between modules
            end
        end

        function helpDocumentationSelected(app, ~)
            appDir = fileparts(mfilename('fullpath'));
            docPath = fullfile(appDir, 'README.md');
            if isfile(docPath)
                web(docPath, '-browser');
            else
                web('https://github.com/Symphony-DAS', '-browser');
            end
        end

        function helpUserGroupSelected(app, ~)
            web('https://groups.google.com/forum/#!forum/symphony-das', '-browser');
        end

        function helpAboutSelected(app, ~)
            msg = sprintf('SymphonyApp\nC# host-backed MATLAB UI\n\nPhase 3 bridge integration');
            uialert(app.UIFigure, msg, 'About SymphonyApp');
        end

        function refreshProtocolPropertyGrid(app)
            app.isProgrammaticPropertyUpdate = true;
            c = onCleanup(@()app.setProgrammaticFalse()); %#ok<NASGU>
            try
                if isempty(app.currentProtocol)
                    % Clear everything
                    ch = app.protocolPropertyGrid.Children;
                    for k = 1:numel(ch), delete(ch(k)); end
                    app.protocolPropertyControls = {};
                    app.protocolPropertyMeta = {};
                    app.protocolPropertyGrid.RowHeight = {22};
                    return;
                end

                % Get properties from the live MATLAB protocol instance
                allProps = symphonyui.ui.ProtocolScanner.getProtocolProperties(app.currentProtocol);

                % Filter out hidden properties
                visible = ~[allProps.isHidden];
                allProps = allProps(visible);

                % Group by category so the extension's parameter sections
                % render together. Stable within a category; categories sorted
                % so numeric-prefixed names ('1 Basic','2 Timing',...) order right.
                if ~isempty(allProps) && isfield(allProps, 'category')
                    cats = strings(1, numel(allProps));
                    for ci = 1:numel(allProps)
                        cc = allProps(ci).category;
                        if isempty(cc), cc = 'zzzz Other'; end
                        cats(ci) = string(cc);
                    end
                    uc = sort(unique(cats));
                    ord = [];
                    for ci = 1:numel(uc)
                        ord = [ord, find(cats == uc(ci))]; %#ok<AGROW>
                    end
                    allProps = allProps(ord);
                end
                n = numel(allProps);

                % Check if the property structure matches existing controls
                % (same names in the same order). If so, just update values.
                canUpdate = (numel(app.protocolPropertyMeta) == n) ...
                    && (numel(app.protocolPropertyControls) == n);
                if canUpdate
                    for i = 1:n
                        if ~strcmp(app.protocolPropertyMeta{i}.Name, allProps(i).name)
                            canUpdate = false;
                            break;
                        end
                    end
                end

                if canUpdate
                    % Fast path: update existing controls in place
                    for i = 1:n
                        p = allProps(i);
                        app.protocolPropertyMeta{i}.Value = p.value;
                        app.protocolPropertyMeta{i}.IsReadOnly = p.isReadOnly;

                        ctrl = app.protocolPropertyControls{i};
                        if ~isvalid(ctrl)
                            canUpdate = false;
                            break;
                        end

                        newDispVal = SymphonyAppUtil.valueToDisplay(p.value);
                        if isa(ctrl, 'matlab.ui.control.DropDown')
                            % Update dropdown items if domain changed
                            if ~isempty(p.domain) && iscell(p.domain)
                                domainItems = cellfun(@(x) strtrim(SymphonyAppUtil.valueToDisplay(x)), ...
                                    p.domain, 'UniformOutput', false);
                                curVal = strtrim(newDispVal);
                                if ~any(strcmp(curVal, domainItems))
                                    domainItems = [domainItems, {curVal}];
                                end
                                ctrl.Items = domainItems;
                                ctrl.Value = curVal;
                            else
                                ctrl.Value = strtrim(newDispVal);
                            end
                        else
                            ctrl.Value = newDispVal;
                        end
                    end
                end

                if canUpdate
                    return;  % Done — no rebuild needed
                end

                % Full rebuild: property structure changed
                ch = app.protocolPropertyGrid.Children;
                for k = 1:numel(ch), delete(ch(k)); end
                app.protocolPropertyControls = {};

                meta = cell(n, 1);
                controls = cell(n, 1);

                % Precompute row layout: insert a header row before each new
                % (non-empty) category so parameters render in labeled sections.
                rowHeights = {};
                rowIsHeader = false(1, 0);
                rowPropIdx = zeros(1, 0);
                rowCat = strings(1, 0);
                lastCat = string(char(1));  % sentinel that won't match a real category
                for i = 1:n
                    c = '';
                    if isfield(allProps, 'category'), c = allProps(i).category; end
                    c = string(c);
                    if strlength(c) > 0 && c ~= "zzzz Other"
                        if c ~= lastCat
                            rowHeights{end+1} = 20; %#ok<AGROW>
                            rowIsHeader(end+1) = true; %#ok<AGROW>
                            rowPropIdx(end+1) = 0; %#ok<AGROW>
                            rowCat(end+1) = c; %#ok<AGROW>
                            lastCat = c;
                        end
                    else
                        lastCat = string(char(1)); % reset so a later categorized prop starts a header
                    end
                    rowHeights{end+1} = 22; %#ok<AGROW>
                    rowIsHeader(end+1) = false; %#ok<AGROW>
                    rowPropIdx(end+1) = i; %#ok<AGROW>
                    rowCat(end+1) = ""; %#ok<AGROW>
                end
                app.protocolPropertyGrid.RowHeight = rowHeights;

                for r = 1:numel(rowHeights)
                    if rowIsHeader(r)
                        % Section header spanning both columns (strip sort prefix)
                        headerText = regexprep(char(rowCat(r)), '^\d+\s+', '');
                        h = uilabel(app.protocolPropertyGrid, ...
                            'Text', headerText, ...
                            'FontSize', 11, ...
                            'FontWeight', 'bold', ...
                            'HorizontalAlignment', 'left');
                        h.Layout.Row = r;
                        h.Layout.Column = [1 2];
                        continue;
                    end

                    i = rowPropIdx(r);
                    p = allProps(i);
                    % Build field-by-field (NOT struct(...)): a cell-valued
                    % p.value would make struct() return a non-scalar struct
                    % array, which later makes meta{i}.Name expand to a
                    % comma-separated list -> strcmp 'Too many input arguments'.
                    mi = struct();
                    mi.Name = p.name;
                    mi.PrimitiveType = p.primitiveType;
                    mi.IsReadOnly = p.isReadOnly;
                    mi.Value = p.value;
                    mi.Domain = p.domain;
                    meta{i} = mi;

                    % Label
                    lbl = uilabel(app.protocolPropertyGrid, ...
                        'Text', p.displayName, ...
                        'FontSize', 11, ...
                        'HorizontalAlignment', 'right');
                    lbl.Layout.Row = r;
                    lbl.Layout.Column = 1;

                    % Value control: dropdown for domain properties, editfield otherwise
                    if ~isempty(p.domain) && iscell(p.domain)
                        domainItems = cellfun(@(x) strtrim(SymphonyAppUtil.valueToDisplay(x)), ...
                            p.domain, 'UniformOutput', false);
                        curVal = strtrim(SymphonyAppUtil.valueToDisplay(p.value));
                        if ~any(strcmp(curVal, domainItems))
                            domainItems = [domainItems, {curVal}];
                        end
                        ctrl = uidropdown(app.protocolPropertyGrid, ...
                            'Items', domainItems, ...
                            'Value', curVal, ...
                            'FontSize', 11, ...
                            'Enable', SymphonyAppUtil.onOff(~p.isReadOnly), ...
                            'ValueChangedFcn', @(s, e) app.onPropertyControlChanged(i, s.Value));
                    elseif islogical(p.value)
                        ctrl = uidropdown(app.protocolPropertyGrid, ...
                            'Items', {'true', 'false'}, ...
                            'Value', SymphonyAppUtil.valueToDisplay(p.value), ...
                            'FontSize', 11, ...
                            'Enable', SymphonyAppUtil.onOff(~p.isReadOnly), ...
                            'ValueChangedFcn', @(s, e) app.onPropertyControlChanged(i, s.Value));
                    else
                        ctrl = uieditfield(app.protocolPropertyGrid, ...
                            'Value', SymphonyAppUtil.valueToDisplay(p.value), ...
                            'FontSize', 11, ...
                            'Editable', SymphonyAppUtil.onOff(~p.isReadOnly), ...
                            'ValueChangedFcn', @(s, e) app.onPropertyControlChanged(i, s.Value));
                    end
                    ctrl.Layout.Row = r;
                    ctrl.Layout.Column = 2;

                    controls{i} = ctrl;
                end

                app.protocolPropertyMeta = meta;
                app.protocolPropertyControls = controls;
            catch ex
                app.protocolPropertyMeta = {};
                app.protocolPropertyControls = {};
                app.showError(ex, 'Protocol Properties Error');
            end
        end

        function setProgrammaticFalse(app)
            app.isProgrammaticPropertyUpdate = false;
        end

        function onPropertyControlChanged(app, row, newValue)
            if app.isProgrammaticPropertyUpdate
                return;
            end
            try
                if row < 1 || row > numel(app.protocolPropertyMeta)
                    return;
                end
                m = app.protocolPropertyMeta{row};
                if m.IsReadOnly
                    return;
                end

                % For domain properties (dropdowns), value is a string from the dropdown.
                % If the original value was numeric, coerce back to the right type.
                if ~isempty(m.Domain) && iscell(m.Domain)
                    if isnumeric(m.Value)
                        propValue = SymphonyAppUtil.coerceValue(newValue, m.PrimitiveType);
                    else
                        propValue = newValue;
                    end
                elseif islogical(m.Value)
                    propValue = strcmp(newValue, 'true');
                else
                    % An empty numeric entry means "no change" -- revert quietly
                    % instead of raising "Value must be numeric".
                    if (ischar(newValue) || isstring(newValue)) && isempty(strtrim(char(newValue)))
                        app.refreshProtocolPropertyGrid();
                        return;
                    end
                    try
                        propValue = SymphonyAppUtil.coerceValue(newValue, m.PrimitiveType);
                    catch
                        % Invalid numeric entry: revert and warn gently, without
                        % the verbose Set Property Error stack dump.
                        app.refreshProtocolPropertyGrid();
                        uialert(app.UIFigure, ...
                            sprintf('"%s" is not a valid value for %s.', char(string(newValue)), m.Name), ...
                            'Invalid value', 'Icon', 'warning');
                        return;
                    end
                end
                propName = m.Name;

                if ~isempty(app.currentProtocol)
                    app.currentProtocol.(propName) = propValue;

                    % Close and reset figure handlers so stale plots from
                    % the previous parameter values don't persist.
                    app.closeFigureHandlers();
                end

                app.refreshProtocolPropertyGrid();
                app.refreshAcquireControls();
                app.refreshPreview();
            catch ex
                app.refreshProtocolPropertyGrid();
                app.showError(ex, 'Set Property Error');
            end
        end

        function [proceed, dontAskAgain] = showViewOnlyWarning(app)
            %SHOWVIEWONLYWARNING  Custom warning dialog with "don't show again" checkbox.
            %   Returns [proceed, dontAskAgain]:
            %     proceed = true if user chose to continue with View Only
            %     dontAskAgain = true if user checked the "don't ask again" box
            proceed = false;
            dontAskAgain = false;

            dlg = uifigure('Name', 'View Only', ...
                'Position', [0 0 420 160], ...
                'WindowStyle', 'modal', ...
                'Resize', 'off');
            % Center on parent
            pp = app.UIFigure.Position;
            dlg.Position(1) = pp(1) + (pp(3) - 420) / 2;
            dlg.Position(2) = pp(2) + (pp(4) - 160) / 2;

            g = uigridlayout(dlg, [3 1]);
            g.RowHeight = {'1x', 22, 36};
            g.Padding = [16 12 16 12];
            g.RowSpacing = 8;

            uilabel(g, 'Text', ...
                'A data file is open but you are about to run in View Only mode. Data will not be recorded. Continue?', ...
                'WordWrap', 'on', 'FontSize', 12);

            cb = uicheckbox(g, 'Text', 'Don''t show this warning again this session', ...
                'Value', false, 'FontSize', 11);
            cb.Layout.Row = 2;

            btnGrid = uigridlayout(g, [1 3]);
            btnGrid.Layout.Row = 3;
            btnGrid.ColumnWidth = {'1x', 90, 80};
            btnGrid.Padding = [0 0 0 0];
            uilabel(btnGrid, 'Text', ''); % Spacer
            uibutton(btnGrid, 'Text', 'View Only', ...
                'ButtonPushedFcn', @(~,~)onViewOnly());
            uibutton(btnGrid, 'Text', 'Cancel', ...
                'ButtonPushedFcn', @(~,~)onCancel());

            dlg.KeyPressFcn = @(~,e)onKey(e);
            symphonyui.ui.DialogUtil.setKeyPressFcnRecursive(dlg, @(~,e)onKey(e));

            uiwait(dlg);

            function onViewOnly()
                proceed = true;
                dontAskAgain = cb.Value;
                delete(dlg);
            end
            function onCancel()
                proceed = false;
                dontAskAgain = false;
                delete(dlg);
            end
            function onKey(event)
                switch event.Key
                    case 'return'
                        onViewOnly();
                    case 'escape'
                        onCancel();
                end
            end
        end

        function closeFigureHandlers(app)
            % Close all figure handlers so they are recreated with fresh
            % device references on the next run. Figure positions are
            % saved/restored by FigureHandler.saveSettings/loadSettings,
            % so the windows reappear where the user left them.
            if ~isempty(app.currentProtocol)
                try
                    app.currentProtocol.closeFigures();
                catch
                end
            end
        end

        function runFileCleanupFunction(~)
            %RUNFILECLEANUPFUNCTION  Execute the file cleanup function from Options.
            %   Called when a data file is closed. The function receives
            %   no arguments in the new UI (the old UI passed documentationService).
            try
                opts = symphonyui.app.Options.getDefault();
                f = opts.fileCleanupFunction;
                if isempty(f) || ~isa(f, 'function_handle')
                    return;
                end
                fprintf('Running file cleanup function: %s\n', func2str(f));
                try
                    % Try calling with no arguments first (new convention)
                    f();
                catch
                    % Fall back to passing [] for documentationService (old convention)
                    try
                        f([]);
                    catch ex2
                        warning('symphonyui:options:fileCleanupFunction', ...
                            'File cleanup function failed: %s', ex2.message);
                    end
                end
            catch ex
                warning('symphonyui:options:fileCleanupFunction', ...
                    'Failed to run file cleanup function: %s', ex.message);
            end
        end

        function runOptionsFile(~, which)
            %RUNOPTIONSFILE  Execute the startup or cleanup file from Options.
            %   which: 'startup' or 'cleanup'
            try
                opts = symphonyui.app.Options.getDefault();
                switch which
                    case 'startup'
                        f = opts.startupFile;
                    case 'cleanup'
                        f = opts.cleanupFile;
                    otherwise
                        return;
                end
                if isempty(f)
                    return;
                end
                if isa(f, 'function_handle')
                    fprintf('Running Options %s function: %s\n', which, func2str(f));
                    f();
                elseif ischar(f) && ~isempty(strtrim(f))
                    fprintf('Running Options %s file: %s\n', which, f);
                    run(f);
                end
            catch ex
                warning('symphonyui:options:%sFile', ...
                    'Failed to run %s file: %s', which, ex.message);
            end
        end

        function viewOnlyButtonPushed(app, ~)
            try
                % Warn if a data file is open and the option is enabled
                if ~app.controller.state.isViewingPaused()
                    try
                        opts = symphonyui.app.Options.getDefault();
                        shouldWarn = logical(opts.warnOnViewOnlyWithOpenFile);
                    catch
                        shouldWarn = true;
                    end
                    if shouldWarn && ~app.suppressViewOnlyWarning
                        try
                            hasFile = app.awaitTaskWithResult(app.host.HasOpenFileAsync());
                        catch
                            hasFile = false;
                        end
                        if hasFile
                            [proceed, dontAskAgain] = app.showViewOnlyWarning();
                            if ~proceed
                                return;
                            end
                            if dontAskAgain
                                app.suppressViewOnlyWarning = true;
                            end
                        end
                    end
                end

                if app.controller.state.isViewingPaused()
                    app.enableRunningControls();
                    app.isAcquiring = true;
                    app.pauseDataManagerDuringAcquisition();
                    app.controller.resume();
                else
                    app.enableRunningControls();
                    app.connectOutOfProcessWriter();
                    app.isAcquiring = true;
                    app.pauseDataManagerDuringAcquisition();
                    app.controller.runProtocol(app.currentProtocol, []);
                end
            catch ex
                app.showError(ex, 'View Only Error');
            end
            app.isAcquiring = false;
            app.disconnectOutOfProcessWriter();
            pause(0.2);  % Allow C# batch queue to finish before Data Manager reads
            app.resumeDataManagerAfterAcquisition();
            app.refreshAcquireControls();
        end

        function rig = macInitializeRigViaListDlg(app)
            %MACINITIALIZERIGVIALISTDLG  Mac/Linux rig selection via listdlg.
            %
            %   The standard UIFigure-based InitializeRigDialog crashes
            %   MATLAB on macOS / Linux because the UIFigure event
            %   dispatch goes through a SingleShotTimer mechanism that
            %   segfaults during error-handler unwinding through the
            %   broken .NET Core bridge. The crash fires *before* any
            %   user code (onInitialize, etc.) runs, so it can't be
            %   caught from MATLAB.
            %
            %   listdlg uses the older Java/Swing dispatch path which
            %   is unaffected. The trade-off is a harmless Java
            %   reflection warning that hg.jar emits on first use —
            %   noise, not a malfunction.

            rig = [];
            try
                rigs = symphonyui.ui.ProtocolScanner.discoverRigs(app.getSearchPaths());
                if isempty(rigs)
                    app.showError('No rig descriptions found on the search path.', ...
                        'Initialize Rig');
                    return;
                end

                labels = arrayfun(@(r) r.displayName, rigs, 'UniformOutput', false);
                ids = arrayfun(@(r) r.id, rigs, 'UniformOutput', false);

                [idx, ok] = listdlg( ...
                    'Name', 'Initialize Rig', ...
                    'PromptString', 'Select rig description:', ...
                    'SelectionMode', 'single', ...
                    'ListString', labels, ...
                    'ListSize', [320, 240]);
                if ~ok
                    return;
                end

                rigId = ids{idx};
                ctorFcn = str2func(rigId);
                description = ctorFcn();
                rig = symphonyui.core.Rig(description);
            catch ex
                app.showError(ex, 'Initialize Rig Error');
            end
        end

        function macViewOnly(app)
            %MACVIEWONLY  Mac/Linux View Only path: createPresentation -> Stage.
            %
            %   Bypasses Controller.runProtocol entirely. Sufficient for
            %   stimulus development; not for acquisition (no recording,
            %   no DAQ I/O, no epoch loop).

            try
                if isempty(app.currentRig)
                    app.showError('No rig is initialized. Use Configure → Initialize Rig.', 'View Only');
                    return;
                end
                if isempty(app.currentProtocol)
                    app.showError('No protocol is selected.', 'View Only');
                    return;
                end

                % Find the VideoDevice (matches SimulationTest's naming)
                videoDevice = [];
                for i = 1:numel(app.currentRig.devices)
                    d = app.currentRig.devices{i};
                    try, n = char(d.name); catch, continue; end
                    if startsWith(n, 'SimulatedStage.Stage@') ...
                            || endsWith(n, 'Stage') ...
                            || contains(n, '.Stage@')
                        videoDevice = d;
                        break;
                    end
                end
                if isempty(videoDevice)
                    app.showError('No VideoDevice found in the current rig.', 'View Only');
                    return;
                end

                presentation = app.currentProtocol.createPresentation();
                if isempty(presentation) || ~isa(presentation, 'stage.core.Presentation')
                    app.showError(['Protocol "' class(app.currentProtocol) ...
                        '" did not return a stage.core.Presentation from createPresentation().'], ...
                        'View Only');
                    return;
                end

                videoDevice.play(presentation);
            catch ex
                app.showError(ex, 'View Only Error');
            end
        end


        function recordButtonPushed(app, ~)
            try
                if app.controller.state.isRecordingPaused()
                    app.enableRunningControls();
                    app.isAcquiring = true;
                    app.pauseDataManagerDuringAcquisition();
                    app.controller.resume();
                else
                    persistor = app.getFilePersistor();
                    app.persistRigDeviceResources();   % in case the rig was initialized after the file was created
                    app.enableRunningControls();
                    app.connectOutOfProcessWriter();
                    app.isAcquiring = true;
                    app.pauseDataManagerDuringAcquisition();
                    app.controller.runProtocol(app.currentProtocol, persistor);
                end
            catch ex
                app.showError(ex, 'Record Error');
            end
            app.isAcquiring = false;
            app.disconnectOutOfProcessWriter();

            % Brief pause to allow the C# batch save queue to finish
            % flushing before the Data Manager reads from HDF5.
            % This ensures no concurrent HDF5 access.
            pause(0.2);

            % Commit the run to disk (see symphonyui.ui.FileCheckpoint).
            checkpointed = app.checkpointFile('run');

            app.resumeDataManagerAfterAcquisition();
            app.refreshAcquireControls();
            app.refreshDataManagerView(checkpointed);  % full rebuild if the file was reopened
        end

        function ok = checkpointFile(app, reason)
            % Close and reopen the data file so everything recorded so far is
            % on disk, keeping the open epoch groups. Returns true when done.
            ok = false;
            try
                ok = symphonyui.ui.FileCheckpoint.run(app.host, reason);
                if ok
                    app.cachedPersistor = [];   % wrapped the closed document
                end
            catch ex
                fprintf(2, 'checkpointFile: %s\n', ex.message);
            end
        end

        function pauseButtonPushed(app, ~)
            try
                app.controller.requestPause();
            catch ex
                app.showError(ex, 'Pause Error');
            end
            % Don't refresh immediately — completeRun will set paused state
            % and the next drawnow in the controller loop will let us update.
            % But once the blocking runProtocol returns, we refresh.
        end

        function stopAndSaveButtonPushed(app, ~)
            try
                state = app.controller.state;
                if state.isStopped()
                    return;
                end
                % Let the current epoch finish naturally so it gets saved,
                % then stop. Unlike requestStop() which discards incomplete
                % epochs, requestStopAfterEpoch() waits for the current
                % epoch to complete and be persisted before stopping.
                app.controller.requestStopAfterEpoch();
            catch ex
                app.showError(ex, 'Stop and Save Error');
            end
            app.refreshAcquireControls();
            % Use incremental update — don't rebuild the entire tree
            app.refreshDataManagerView(false);
        end

        function stopAndDeleteButtonPushed(app, ~)
            try
                % Check if we're actively recording to a file
                isActive = false;
                hasFile = false;
                try
                    state = app.controller.state;
                    isActive = state.isRunning();
                    hasFile = ~isempty(app.controller.currentPersistor);
                catch
                end

                % Show the "Save Partial?" dialog if recording AND streaming
                % is enabled. For non-streaming epochs the dialog is skipped.
                isStreaming = false;
                try
                    opts = symphonyui.app.Options.getDefault();
                    if opts.streamingEnabled && isActive && hasFile
                        isStreaming = true;
                    end
                catch
                end

                fprintf('stopAndDelete: isActive=%d, hasFile=%d, isStreaming=%d\n', isActive, hasFile, isStreaming);
                if isActive && hasFile && isStreaming
                    % Streaming epoch — offer to save partial data
                    answer = uiconfirm(app.UIFigure, ...
                        'Save data from the current (partial) epoch?', ...
                        'Stop Acquisition', ...
                        'Options', {'Save Partial', 'Discard', 'Cancel'}, ...
                        'DefaultOption', 1, ...
                        'CancelOption', 3, ...
                        'Icon', 'question');

                    switch answer
                        case 'Save Partial'
                            app.stopActiveVideoDevices();
                            app.controller.requestStopAndSavePartial();
                        case 'Discard'
                            app.stopActiveVideoDevices();
                            app.controller.requestStop();
                        case 'Cancel'
                            return;
                    end
                else
                    % Short epoch, View Only mode, or not running — just stop.
                    % Also interrupt any in-progress Stage presentation so
                    % the display doesn't keep rendering past the stop.
                    app.stopActiveVideoDevices();
                    app.controller.requestStop();
                end
            catch ex
                app.showError(ex, 'Stop Error');
            end
            app.refreshAcquireControls();
            % Use incremental update
            app.refreshDataManagerView(false);
        end

        function stopActiveVideoDevices(app)
            % Interrupts any in-progress Stage presentation in the current
            % rig. Called from stopAndDeleteButtonPushed so that pressing
            % Stop and Delete immediately halts the visual stimulus, not
            % just the DAQ acquisition. Natural epoch completion does NOT
            % call this — Stage is allowed to run presentations to their
            % full duration in the normal path.
            %
            % Iterates all devices on the current rig and invokes stop() on
            % any VideoDevice. stop() is tolerant of "no active play" and
            % returns quietly if there's nothing to interrupt, so it's safe
            % to call even when we're not sure a presentation is running.
            try
                if isempty(app.currentRig)
                    return;
                end
                devices = app.currentRig.devices;
                for i = 1:numel(devices)
                    dev = devices{i};
                    if isa(dev, 'symphonyui.builtin.devices.VideoDevice')
                        try
                            dev.stop();
                        catch ex
                            fprintf(2, ['[stopActiveVideoDevices] ' ...
                                'failed to stop %s: %s\n'], ...
                                class(dev), ex.message);
                        end
                    end
                end
            catch ex
                % Should never happen — stop is a best-effort helper, never
                % block the user-driven stop path on our own failures.
                fprintf(2, '[stopActiveVideoDevices] unexpected error: %s\n', ...
                    ex.message);
            end
        end

        function enableRunningControls(app)
            % Pre-enable pause/stop buttons before the blocking runProtocol call.
            app.viewOnlyButton.Enable = 'off';
            app.recordButton.Enable = 'off';
            app.pauseButton.Enable = 'on';
            app.stopAndDeleteButton.Enable = 'on';
            app.stopAndSaveButton.Enable = 'on';
            app.statusLabel.Text = 'Status: Running';
            drawnow;
        end

        function connectOutOfProcessWriter(app)
            % Connect the out-of-process HDF5 writer to the C# Controller.
            % If the writer process is running, hand off the file and route
            % ALL HDF5 operations (epochs, epoch blocks) through it.
            try
                writer = app.host.GetOutOfProcessWriter();
                if ~isempty(writer) && writer.IsConnected
                    % Hand off file: close in-process, open in writer
                    app.host.HandoffToWriter();
                    app.controller.cobj.OutOfProcessWriter = writer;
                else
                    app.controller.cobj.OutOfProcessWriter = [];
                end
            catch ex
                fprintf(2, 'connectOutOfProcessWriter: %s\n', ex.message);
                try app.controller.cobj.OutOfProcessWriter = []; catch, end
            end
        end

        function disconnectOutOfProcessWriter(app)
            % Hand back the file from the writer process after acquisition.
            try
                app.controller.cobj.OutOfProcessWriter = [];
                app.host.HandoffFromWriter();
            catch
            end
        end

        function p = getFilePersistor(app)
            % Get the MATLAB-side Persistor wrapping the C# host's H5EpochPersistor.
            % Caches the wrapper so the same instance is reused across recordings.
            % (Creating a new Persistor each time causes MATLAB's GC to call
            % delete() on the old wrapper, which closes the underlying C# persistor.)
            try
                % Return cached wrapper if it's still valid, open, and still
                % wraps the host's current C# persistor (a file checkpoint
                % replaces that object without changing IsClosed).
                cper = app.host.GetPersistor();
                if ~isempty(app.cachedPersistor) && isvalid(app.cachedPersistor) ...
                        && ~app.cachedPersistor.isClosed ...
                        && ~isempty(cper) && System.Object.ReferenceEquals(app.cachedPersistor.cobj, cper)
                    p = app.cachedPersistor;
                    return;
                end
                app.cachedPersistor = [];

                if isempty(cper)
                    error('symphonyui:app:noFile', ...
                        'No data file is open. Create or open a file first.');
                end
                app.cachedPersistor = symphonyui.core.Persistor(cper, ...
                    symphonyui.core.persistent.EntityFactory(), false);
                p = app.cachedPersistor;
            catch ex
                fprintf(2, 'Warning: Could not get persistor: %s\n', ex.message);
                rethrow(ex);
            end
        end

        function refreshAcquireControls(app)
            if app.isAcquiring
                return;  % Don't query HDF5 state during acquisition
            end
            try
                state = app.controller.state;
                stateName = char(state);

                isStopped = state.isStopped();
                isStopping = state.isStopping();
                isPausing = state.isPausing();
                isViewingPaused = state.isViewingPaused();
                isRecordingPaused = state.isRecordingPaused();

                % Check for open epoch group — use cached value to avoid
                % HDF5 reads. The cache is updated by hasOpenEpochGroup().
                hasEpochGroup = app.hasOpenEpochGroup();

                % Valid when both protocol and rig are set on the MATLAB side
                isValid = ~isempty(app.currentProtocol) && ~isempty(app.currentRig);
                validationMsg = '';
                if isempty(app.currentRig)
                    validationMsg = 'No rig initialized';
                elseif isempty(app.currentProtocol)
                    validationMsg = 'No protocol selected';
                end

                enableViewOnly = isValid && (isViewingPaused || isStopped);
                enableRecord = isValid && hasEpochGroup && (isRecordingPaused || isStopped);
                enablePause = ~isPausing && ~isViewingPaused && ~isRecordingPaused && ~isStopping && ~isStopped;
                enableStop = ~isStopping && ~isStopped;
                enableStopAndSave = enableStop;

                app.viewOnlyButton.Enable = SymphonyAppUtil.onOff(enableViewOnly);
                app.recordButton.Enable = SymphonyAppUtil.onOff(enableRecord);
                app.pauseButton.Enable = SymphonyAppUtil.onOff(enablePause);
                app.stopAndDeleteButton.Enable = SymphonyAppUtil.onOff(enableStop);
                app.stopAndSaveButton.Enable = SymphonyAppUtil.onOff(enableStopAndSave);

                if ~isValid
                    if isempty(validationMsg)
                        validationMsg = 'Invalid protocol';
                    end
                    app.statusLabel.Text = ['Status: ' validationMsg];
                else
                    app.statusLabel.Text = ['Status: ' stateName];
                end
            catch ex
                app.showError(ex, 'State Update Error');
            end
        end

        function stateName = getControllerStateName(app)
            stateName = char(app.controller.state);
        end

        function waitForPausedState(app, timeoutSeconds)
            if nargin < 2
                timeoutSeconds = 8.0;
            end

            t0 = tic;
            while toc(t0) < timeoutSeconds
                stateName = app.getControllerStateName();
                if strcmp(stateName, 'ViewingPaused') || strcmp(stateName, 'RecordingPaused') || strcmp(stateName, 'Stopped')
                    return;
                end
                pause(0.05);
                drawnow limitrate;
            end

            % Timeout is treated as a soft failure. We still allow stop request.
        end

        function awaitTask(app, task) %#ok<INUSL>
            task.GetAwaiter().GetResult();
        end

        function result = awaitTaskWithResult(app, task) %#ok<INUSL>
            result = task.GetAwaiter().GetResult();
        end

        function showError(app, msgOrException, title)
            if nargin < 3
                title = 'Error';
            end

            % Accept either a string message or an MException
            if isa(msgOrException, 'MException')
                ex = msgOrException;
                msg = ex.message;
                % Dump full stack trace to command window
                fprintf(2, '\n=== %s ===\n', title);
                fprintf(2, '%s: %s\n', ex.identifier, ex.message);
                for k = 1:numel(ex.stack)
                    fprintf(2, '  in %s (line %d)\n', ex.stack(k).name, ex.stack(k).line);
                end
                cause = ex;
                while ~isempty(cause.cause)
                    cause = cause.cause{1};
                    fprintf(2, 'Caused by: %s: %s\n', cause.identifier, cause.message);
                    for k = 1:numel(cause.stack)
                        fprintf(2, '  in %s (line %d)\n', cause.stack(k).name, cause.stack(k).line);
                    end
                end
                fprintf(2, '====%s====\n\n', repmat('=', 1, strlength(string(title))));
            else
                msg = msgOrException;
            end

            try
                uialert(app.UIFigure, char(msg), title);
            catch
                disp(msg);
            end
        end
    end

    methods (Access = private)
        function createComponents(app)
            pathToRoot = fileparts(mfilename('fullpath'));
            iconPath = fullfile(pathToRoot, 'code', 'src', 'resources', 'icons');

            app.UIFigure = uifigure('Visible', 'off');
            app.UIFigure.Position = [100 100 360 550];
            app.UIFigure.Resize = 'on';
            app.UIFigure.AutoResizeChildren = 'off'; %[100 100 390 560]; appbox.screenCenter(360,500);
            app.UIFigure.Name = 'SymphonyApp';

            app.fileMenu = uimenu(app.UIFigure, 'Text', 'File');
            app.documentMenu = uimenu(app.UIFigure, 'Text', 'Document');
            app.AcquireMenu = uimenu(app.UIFigure, 'Text', 'Acquire');
            app.ConfigureMenu = uimenu(app.UIFigure, 'Text', 'Configure');
            app.ModulesMenu = uimenu(app.UIFigure, 'Text', 'Modules');
            app.PreviewMenu = uimenu(app.UIFigure, 'Text', 'Preview');
            uimenu(app.PreviewMenu, 'Text', 'Show Preview Window', ...
                'MenuSelectedFcn', createCallbackFcn(app, @previewShowSelected, true));
            app.HelpMenu = uimenu(app.UIFigure, 'Text', 'Help');

            app.newFileMenu = uimenu(app.fileMenu, 'Text', 'New...   Ctrl+N', ...
                'MenuSelectedFcn', createCallbackFcn(app, @fileNewSelected, true));
            app.openFileMenu = uimenu(app.fileMenu, 'Text', 'Open...   Ctrl+O', ...
                'MenuSelectedFcn', createCallbackFcn(app, @fileOpenSelected, true));
            app.closeFileMenu = uimenu(app.fileMenu, 'Text', 'Close', ...
                'MenuSelectedFcn', createCallbackFcn(app, @fileCloseSelected, true));
            app.exitMenu = uimenu(app.fileMenu, 'Text', 'Exit', 'Separator', 'on', ...
                'MenuSelectedFcn', createCallbackFcn(app, @fileExitSelected, true));

            app.addSourceMenu = uimenu(app.documentMenu, 'Text', 'Add Source...', ...
                'MenuSelectedFcn', createCallbackFcn(app, @documentAddSourceSelected, true));
            app.beginEpochGroupMenu = uimenu(app.documentMenu, 'Text', 'Begin Epoch Group...   Ctrl+B', 'Separator', 'on', ...
                'MenuSelectedFcn', createCallbackFcn(app, @documentBeginEpochGroupSelected, true));
            app.endEpochGroupMenu = uimenu(app.documentMenu, 'Text', 'End Epoch Group   Ctrl+E', ...
                'MenuSelectedFcn', createCallbackFcn(app, @documentEndEpochGroupSelected, true));
            app.addNoteMenu = uimenu(app.documentMenu, 'Text', 'Add Note to Experiment...   Ctrl+T', 'Separator', 'on', ...
                'MenuSelectedFcn', createCallbackFcn(app, @documentAddNoteSelected, true));

            app.acquireViewOnlyMenu = uimenu(app.AcquireMenu, 'Text', 'View Only', ...
                'MenuSelectedFcn', createCallbackFcn(app, @acquireViewOnlySelected, true));
            app.acquireRecordMenu = uimenu(app.AcquireMenu, 'Text', 'Record', ...
                'MenuSelectedFcn', createCallbackFcn(app, @acquireRecordSelected, true));
            app.acquirePauseMenu = uimenu(app.AcquireMenu, 'Text', 'Pause', ...
                'MenuSelectedFcn', createCallbackFcn(app, @acquirePauseSelected, true));
            app.acquireStopMenu = uimenu(app.AcquireMenu, 'Text', 'Stop', ...
                'MenuSelectedFcn', createCallbackFcn(app, @acquireStopSelected, true));
            app.acquireResetProtocolMenu = uimenu(app.AcquireMenu, 'Text', 'Reset Protocol', 'Separator', 'on', ...
                'MenuSelectedFcn', createCallbackFcn(app, @acquireResetProtocolSelected, true));
            app.acquireProtocolPresetsMenu = uimenu(app.AcquireMenu, 'Text', 'Protocol Presets', ...
                'MenuSelectedFcn', createCallbackFcn(app, @acquireProtocolPresetsSelected, true));

            app.initializeRigMenu = uimenu(app.ConfigureMenu, 'Text', 'Initialize Rig...', ...
                'MenuSelectedFcn', createCallbackFcn(app, @configureInitializeRigSelected, true));
            app.configureDevicesMenu = uimenu(app.ConfigureMenu, 'Text', 'Devices', ...
                'MenuSelectedFcn', createCallbackFcn(app, @configureDevicesSelected, true));
            app.configureOptionsMenu = uimenu(app.ConfigureMenu, 'Text', 'Options', 'Separator', 'on', ...
                'MenuSelectedFcn', createCallbackFcn(app, @configureOptionsSelected, true));
            app.rigBuilderMenu = uimenu(app.ConfigureMenu, 'Text', 'Rig Builder...', 'Separator', 'on', ...
                'MenuSelectedFcn', createCallbackFcn(app, @configureRigBuilderSelected, true));
            app.protocolBuilderMenu = uimenu(app.ConfigureMenu, 'Text', 'Protocol Builder...', ...
                'MenuSelectedFcn', createCallbackFcn(app, @configureProtocolBuilderSelected, true));

            app.modulesRefreshMenu = uimenu(app.ModulesMenu, 'Text', 'Refresh Modules', 'Separator', 'on', ...
                'MenuSelectedFcn', createCallbackFcn(app, @modulesRefreshSelected, true));

            app.helpDocumentationMenu = uimenu(app.HelpMenu, 'Text', 'Documentation', ...
                'MenuSelectedFcn', createCallbackFcn(app, @helpDocumentationSelected, true));
            app.helpUserGroupMenu = uimenu(app.HelpMenu, 'Text', 'User Group', ...
                'MenuSelectedFcn', createCallbackFcn(app, @helpUserGroupSelected, true));
            app.helpAboutMenu = uimenu(app.HelpMenu, 'Text', 'About SymphonyApp', 'Separator', 'on', ...
                'MenuSelectedFcn', createCallbackFcn(app, @helpAboutSelected, true));

            app.ProtocolDropDownLabel = uilabel(app.UIFigure);
            app.ProtocolDropDownLabel.HorizontalAlignment = 'right';
            app.ProtocolDropDownLabel.Position = [5 528 45 22];
            app.ProtocolDropDownLabel.Text = 'Protocol';

            app.protocolPopupMenu = uidropdown(app.UIFigure);
            app.protocolPopupMenu.Position = [68 528 287 22]; %[68 528 312 22];
            app.protocolPopupMenu.ValueChangedFcn = createCallbackFcn(app, @protocolPopupMenuValueChanged, true);

            app.protocolPanel = uipanel(app.UIFigure);
            app.protocolPanel.Title = 'Protocol';
            app.protocolPanel.Position = [10 106 340 415]; %[10 106 370 415];
            app.protocolPanel.BackgroundColor = [1 1 1];

            % Scrollable panel for property rows (label + edit/dropdown per row)
            layout = uigridlayout(app.protocolPanel, [1 1]);
            layout.RowHeight = {'1x'};
            layout.ColumnWidth = {'1x'};
            layout.Padding = [2 2 2 2];
            app.protocolPropertyGrid = uigridlayout(layout, [1 2]);
            app.protocolPropertyGrid.ColumnWidth = {'4x', '6x'}; %{'1x', '1x'};
            app.protocolPropertyGrid.RowSpacing = 2;
            app.protocolPropertyGrid.Padding = [4 4 4 4];
            app.protocolPropertyGrid.Scrollable = 'on';

            app.viewOnlyButton = uibutton(app.UIFigure, 'push');
            app.viewOnlyButton.Icon = fullfile(iconPath, 'view_only_bigger.png');
            app.viewOnlyButton.Tooltip = {'View Only'};
            app.viewOnlyButton.Position = [10 52 64 45];
            app.viewOnlyButton.Text = '';
            app.viewOnlyButton.ButtonPushedFcn = createCallbackFcn(app, @viewOnlyButtonPushed, true);

            app.recordButton = uibutton(app.UIFigure, 'push');
            app.recordButton.Icon = fullfile(iconPath, 'record_bigger.png');
            app.recordButton.Tooltip = {'Record'};
            app.recordButton.Position = [78 52 64 45];
            app.recordButton.Text = '';
            app.recordButton.ButtonPushedFcn = createCallbackFcn(app, @recordButtonPushed, true);

            app.pauseButton = uibutton(app.UIFigure, 'push');
            app.pauseButton.Icon = fullfile(iconPath, 'pause_bigger.png');
            app.pauseButton.Tooltip = {'Pause'};
            app.pauseButton.Position = [146 52 64 45];
            app.pauseButton.Text = '';
            app.pauseButton.ButtonPushedFcn = createCallbackFcn(app, @pauseButtonPushed, true);

            app.stopAndSaveButton = uibutton(app.UIFigure, 'push');
            app.stopAndSaveButton.Icon = fullfile(iconPath, 'stop_bigger.png');
            app.stopAndSaveButton.Tooltip = {'Stop and Save'; 'Last Epoch'};
            app.stopAndSaveButton.Position = [214 52 64 45];
            app.stopAndSaveButton.Text = '';
            app.stopAndSaveButton.ButtonPushedFcn = createCallbackFcn(app, @stopAndSaveButtonPushed, true);

            app.stopAndDeleteButton = uibutton(app.UIFigure, 'push');
            app.stopAndDeleteButton.Icon = fullfile(iconPath, 'stop_delete_bigger.png');
            app.stopAndDeleteButton.Tooltip = {'Stop and Delete'; 'Last Epoch'};
            app.stopAndDeleteButton.Position = [282 52 64 45];
            app.stopAndDeleteButton.Text = '';
            app.stopAndDeleteButton.ButtonPushedFcn = createCallbackFcn(app, @stopAndDeleteButtonPushed, true);

            app.statusLabel = uilabel(app.UIFigure);
            app.statusLabel.Position = [10 20 370 22];
            app.statusLabel.Text = 'Status: Stopped';

            app.UIFigure.WindowKeyPressFcn = createCallbackFcn(app, @onWindowKeyPress, true);

            app.UIFigure.SizeChangedFcn = @(~,~) app.onWindowResize();
            app.onWindowResize();  % initial reflow
            app.UIFigure.Visible = 'on';
        end
    end

    methods (Static)
        function preloadModulesIfValid(app)
            % Timer-safe entry to preloadModules: a timer callback cannot be
            % an instance method call, because that errors before any
            % isvalid check can run when the app has been deleted.
            if isvalid(app)
                app.preloadModules();
            end
        end
    end

    methods (Access = public)

        % ---- Module-facing API (used by symphonyui.ui.ModuleAcquisitionAdapter) ----
        % These expose the same code paths as the UI controls so extension
        % modules (e.g. sa_labs.modules.ReceptiveFieldMapper) can drive
        % acquisition exactly as a user would.

        function persistRigDeviceResources(app)
            % Copy every rig device's resources (calibration tables, LightCrafter
            % fits, configurationSettingDescriptors, ...) into the open file.
            % Symphony 2's C# persistor did this when it serialized devices; the
            % Symphony 3 host writes the device groups without their resources,
            % and the lab's DataJoint importer builds its calibration map from
            % them. Safe to call repeatedly: existing resources are skipped.
            if isempty(app.currentRig)
                return;
            end
            try
                cper = app.host.GetPersistor();
            catch
                cper = [];
            end
            if isempty(cper)
                return;
            end
            factory = symphonyui.core.persistent.EntityFactory();
            devices = app.currentRig.devices;
            for i = 1:numel(devices)
                d = devices{i};
                try
                    names = d.getResourceNames();
                    if isempty(names)
                        continue;
                    end
                    cdev = cper.Device(d.name, d.manufacturer);   % get-or-add
                    pd = factory.create(cdev);
                    existing = pd.getResourceNames();
                    for k = 1:numel(names)
                        if any(strcmp(existing, names{k}))
                            continue;
                        end
                        pd.addResource(names{k}, d.getResource(names{k}));
                    end
                catch ex
                    fprintf(2, 'Could not persist resources of device %s: %s\n', char(d.name), ex.message);
                end
            end
        end

        function selectProtocolById(app, protocolId)
            % Select a protocol by class name (e.g. 'sa_labs.protocols.Pulse').
            names = app.protocolIdsByDisplayName.keys;
            for i = 1:numel(names)
                if strcmp(app.protocolIdsByDisplayName(names{i}), protocolId)
                    if ~strcmp(app.protocolPopupMenu.Value, names{i})
                        app.protocolPopupMenu.Value = names{i};
                        app.protocolPopupMenuValueChanged([]);
                    end
                    return;
                end
            end
            error('Protocol ''%s'' was not found in the search paths', protocolId);
        end

        function p = getCurrentProtocol(app)
            p = app.currentProtocol;
        end

        function viewOnly(app)
            app.viewOnlyButtonPushed([]);
        end

        function record(app)
            app.recordButtonPushed([]);
        end

        function stopAcquisition(app)
            app.acquireStopSelected([]);
        end

        function s = getControllerState(app)
            % Controller state as a symphonyui.core.ControllerState (or [] if
            % no controller exists yet).
            if isempty(app.controller)
                s = [];
            else
                s = app.controller.state;
            end
        end
        function applyProtocolPropertyMap(app, propertyMap)
            % Apply a property map to the current protocol WITHOUT switching
            % protocols. Public so modules (e.g. CommonControl, via
            % ModuleAcquisitionAdapter) can push values in. Missing
            % properties on the current protocol are skipped.
            if ~isempty(app.currentProtocol) && ~isempty(propertyMap)
                propKeys = propertyMap.keys;
                for i = 1:numel(propKeys)
                    k = propKeys{i};
                    try
                        app.currentProtocol.(k) = propertyMap(k);
                    catch
                    end
                end
            end
            app.refreshProtocolPropertyGrid();
            app.refreshAcquireControls();
            app.refreshPreview();
        end

        function app = SymphonyApp
            createComponents(app);
            registerApp(app, app.UIFigure);
            runStartupFcn(app, @startupFcn);

            if nargout == 0
                clear app
            end
        end

        function delete(app)
            % Stop the module preloader before anything else so it cannot
            % fire on the deleted app (see initializeRig).
            try
                tm = timerfind('Tag', 'ModulePreloader');
                if ~isempty(tm)
                    stop(tm);
                    delete(tm);
                end
            catch
            end

            % Run the Options cleanup file (if configured)
            app.runOptionsFile('cleanup');

            % Close the rig BEFORE the rest of shutdown so hardware and
            % network connections are released cleanly: the LightCrafter
            % device disconnects its Stage-server socket (netbox serves one
            % client at a time, so a lingering socket blocks the next
            % session's rig init), and the MultiClamp telegraph is freed.
            % Without this, quitting and reopening Symphony hangs on the
            % next initializeRig. Mirrors the pre-init close at rig switch.
            try
                if ~isempty(app.currentRig)
                    app.currentRig.close();
                    app.currentRig = [];
                end
            catch
            end

            % Close HDF5 file BEFORE shutdown to prevent dual-library crash.
            % MATLAB's built-in hdf5.dll and our C# HDF5 P/Invoke share the
            % same native library. If handles are left open when MATLAB's
            % cleanup runs, the HDF5 context assertion fires → abort().
            try
                cper = app.host.GetPersistor();
                if ~isempty(cper) && ~cper.IsClosed
                    cper.Close();
                    fprintf('SymphonyApp: HDF5 file closed before shutdown.\n');
                end
            catch
            end

            % Clear cached persistor so nothing else tries to use it
            app.cachedPersistor = [];

            try
                if ~isempty(app.host)
                    app.awaitTask(app.host.ShutdownAsync());
                end
            catch
            end
            app.closeDataManager();
            app.symphonyDataManager = [];
            if ~isempty(app.legacyContext)
                delete(app.legacyContext);
                app.legacyContext = [];
            end
            if isvalid(app.UIFigure)
                delete(app.UIFigure);
            end
        end
    end
end