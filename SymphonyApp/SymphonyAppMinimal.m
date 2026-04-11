classdef SymphonyAppMinimal < matlab.apps.AppBase
    % Minimal host-integration app for debugging protocol + acquire controls.

    properties (Access = public)
        UIFigure matlab.ui.Figure
        fileMenu matlab.ui.container.Menu
        documentMenu matlab.ui.container.Menu
        AcquireMenu matlab.ui.container.Menu
        ConfigureMenu matlab.ui.container.Menu
        ModulesMenu matlab.ui.container.Menu
        HelpMenu matlab.ui.container.Menu
        ProtocolDropDownLabel matlab.ui.control.Label
        protocolPopupMenu matlab.ui.control.DropDown
        protocolPanel matlab.ui.container.Panel
        protocolPreviewPanel matlab.ui.container.Panel
        viewOnlyButton matlab.ui.control.Button
        recordButton matlab.ui.control.Button
        pauseButton matlab.ui.control.Button
        stopAndDeleteButton matlab.ui.control.Button
        statusLabel matlab.ui.control.Label
    end

    properties (Access = private)
        host
        protocolIdsByDisplayName
        isProgrammaticPropertyUpdate logical = false
        protocolPropertyGrid matlab.ui.control.Table
        protocolPropertyMeta cell = {}
    end

    methods (Access = private)
        function startupFcn(app)
            app.addCodePaths();
            app.initHost();
            app.populateProtocolDropdown();
            app.refreshProtocolPropertyGrid();
            app.refreshAcquireControls();
        end

        function addCodePaths(app) %#ok<MANU>
            appDir = fileparts(mfilename('fullpath'));
            addpath(genpath(fullfile(appDir, 'code', 'lib')));
            addpath(fullfile(appDir, 'code', 'src', 'matlab'));
            addpath(fullfile(appDir, 'code', 'matlab'));
        end

        function initHost(app)
            appDir = fileparts(mfilename('fullpath'));
            coreDir = fullfile(appDir, 'symphony-core');

            NET.addAssembly(fullfile(coreDir, 'Symphony.Core', 'bin', 'Debug', 'net10.0', 'Symphony.Core.dll'));
            NET.addAssembly(fullfile(coreDir, 'Symphony.Acquisition', 'bin', 'Debug', 'net10.0', 'Symphony.Acquisition.dll'));

            dispatcher = Symphony.Acquisition.Bridge.StarterMatlabCommandDispatcher();
            app.host = Symphony.Acquisition.HostFactory.CreateWithInProcessDispatcher(dispatcher);

            initReq = Symphony.Acquisition.Contracts.HostInitRequest(".", "", "", "./logs");
            app.awaitTask(app.host.InitializeAsync(initReq));
            app.awaitTask(app.host.InitializeRigAsync("io.github.symphony.rigs.SimRig"));
        end

        function populateProtocolDropdown(app)
            protocols = app.awaitTaskWithResult(app.host.GetAvailableProtocolsAsync());
            app.protocolIdsByDisplayName = containers.Map('KeyType', 'char', 'ValueType', 'char');

            n = SymphonyAppUtil.getNetCount(protocols);
            items = cell(1, n + 1);
            items{1} = '(None)';
            for i = 1:n
                p = SymphonyAppUtil.getNetItem(protocols, i);
                name = char(p.DisplayName);
                id = char(p.Id);
                items{i + 1} = name;
                app.protocolIdsByDisplayName(name) = id;
            end
            app.protocolPopupMenu.Items = items;
            app.protocolPopupMenu.Value = '(None)';
        end

        function protocolPopupMenuValueChanged(app, ~)
            try
                selectedName = app.protocolPopupMenu.Value;
                if strcmp(selectedName, '(None)')
                    app.awaitTask(app.host.SelectProtocolAsync([]));
                else
                    app.awaitTask(app.host.SelectProtocolAsync(app.protocolIdsByDisplayName(selectedName)));
                end
                app.refreshProtocolPropertyGrid();
                app.refreshAcquireControls();
            catch ex
                app.showError(ex.message, 'Protocol Error');
            end
        end

        function refreshProtocolPropertyGrid(app)
            app.isProgrammaticPropertyUpdate = true;
            c = onCleanup(@()app.setProgrammaticFalse());
            %#ok<NASGU>
            try
                descriptors = app.awaitTaskWithResult(app.host.GetProtocolPropertiesAsync());
                n = SymphonyAppUtil.getNetCount(descriptors);
                rows = cell(n, 2);
                meta = cell(n, 1);
                for i = 1:n
                    d = SymphonyAppUtil.getNetItem(descriptors, i);
                    name = char(d.Name);
                    displayName = char(d.DisplayName);
                    primitiveType = char(d.PrimitiveType);
                    isReadOnly = logical(d.IsReadOnly);
                    value = SymphonyAppUtil.netToMatlabValue(d.Value);

                    rows{i, 1} = displayName;
                    rows{i, 2} = SymphonyAppUtil.valueToDisplay(value);
                    meta{i} = struct( ...
                        'Name', name, ...
                        'PrimitiveType', primitiveType, ...
                        'IsReadOnly', isReadOnly, ...
                        'Value', value);
                end
                app.protocolPropertyMeta = meta;
                app.protocolPropertyGrid.Data = rows;
            catch ex
                app.protocolPropertyMeta = {};
                app.protocolPropertyGrid.Data = {};
                app.showError(ex.message, 'Protocol Properties Error');
            end
        end

        function setProgrammaticFalse(app)
            app.isProgrammaticPropertyUpdate = false;
        end

        function protocolPropertyGridChanged(app, eventData)
            if app.isProgrammaticPropertyUpdate
                return;
            end
            if eventData.Indices(2) ~= 2
                return;
            end
            try
                row = eventData.Indices(1);
                if row < 1 || row > numel(app.protocolPropertyMeta)
                    return;
                end
                m = app.protocolPropertyMeta{row};
                if m.IsReadOnly
                    app.revertPropertyRow(row, m.Value);
                    return;
                end

                typedValue = SymphonyAppUtil.coerceValue(eventData.NewData, m.PrimitiveType);
                app.awaitTask(app.host.SetProtocolPropertyAsync(m.Name, typedValue));
                app.refreshProtocolPropertyGrid();
                app.refreshAcquireControls();
            catch ex
                try
                    m = app.protocolPropertyMeta{eventData.Indices(1)};
                    app.revertPropertyRow(eventData.Indices(1), m.Value);
                catch
                end
                app.refreshProtocolPropertyGrid();
                app.showError(ex.message, 'Set Property Error');
            end
        end

        function revertPropertyRow(app, row, value)
            d = app.protocolPropertyGrid.Data;
            if row >= 1 && row <= size(d, 1)
                d{row, 2} = SymphonyAppUtil.valueToDisplay(value);
                app.protocolPropertyGrid.Data = d;
            end
        end

        function viewOnlyButtonPushed(app, ~)
            try
                app.awaitTask(app.host.ViewOnlyAsync());
            catch ex
                app.showError(ex.message, 'View Only Error');
            end
            app.refreshAcquireControls();
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
                end
            end
        end

        function fileNewSelected(app, ~)
            try
                [filename, pathname] = uiputfile({'*.h5;*.hdf5', 'Symphony Files (*.h5, *.hdf5)'; '*.*', 'All Files'}, 'New File');
                if isequal(filename, 0) || isequal(pathname, 0)
                    return;
                end
                [~, name, ext] = fileparts(filename);
                req = Symphony.Acquisition.Contracts.NewFileRequest([name ext], pathname, "io.github.symphony.experiment.DefaultExperiment");
                app.awaitTask(app.host.NewFileAsync(req));
                app.refreshAcquireControls();
            catch ex
                app.showError(ex.message, 'New File Error');
            end
        end

        function fileOpenSelected(app, ~)
            try
                [filename, pathname] = uigetfile({'*.h5;*.hdf5', 'Symphony Files (*.h5, *.hdf5)'; '*.*', 'All Files'}, 'Open File');
                if isequal(filename, 0) || isequal(pathname, 0)
                    return;
                end
                app.awaitTask(app.host.OpenFileAsync(fullfile(pathname, filename)));
                app.refreshAcquireControls();
            catch ex
                app.showError(ex.message, 'Open File Error');
            end
        end

        function fileCloseSelected(app, ~)
            try
                app.awaitTask(app.host.CloseFileAsync());
                app.refreshAcquireControls();
            catch ex
                app.showError(ex.message, 'Close File Error');
            end
        end

        function fileExitSelected(app, ~)
            delete(app);
        end

        function documentAddSourceSelected(app, ~)
            try
                app.awaitTask(app.host.AddSourceAsync("Source"));
                app.refreshAcquireControls();
            catch ex
                app.showError(ex.message, 'Add Source Error');
            end
        end

        function documentBeginEpochGroupSelected(app, ~)
            try
                app.awaitTask(app.host.BeginEpochGroupAsync("EpochGroup"));
                app.refreshAcquireControls();
            catch ex
                app.showError(ex.message, 'Begin Epoch Group Error');
            end
        end

        function documentEndEpochGroupSelected(app, ~)
            try
                app.awaitTask(app.host.EndEpochGroupAsync());
                app.refreshAcquireControls();
            catch ex
                app.showError(ex.message, 'End Epoch Group Error');
            end
        end

        function documentAddNoteSelected(app, ~)
            try
                answer = inputdlg('Note text:', 'Add Note to Experiment', [1 60]);
                if isempty(answer)
                    return;
                end
                app.awaitTask(app.host.AddNoteToExperimentAsync(answer{1}));
            catch ex
                app.showError(ex.message, 'Add Note Error');
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
                app.showError(ex.message, 'Reset Protocol Error');
            end
        end

        function acquireProtocolPresetsSelected(app, ~)
            try
                presets = app.awaitTaskWithResult(app.host.GetProtocolPresetNamesAsync());
                n = SymphonyAppUtil.getNetCount(presets);
                names = cell(1, n);
                for i = 1:n
                    names{i} = char(SymphonyAppUtil.getNetItem(presets, i));
                end
                if isempty(names)
                    uialert(app.UIFigure, 'No protocol presets available.', 'Protocol Presets');
                    return;
                end
                [idx, ok] = listdlg('PromptString', 'Select preset to apply:', 'SelectionMode', 'single', 'ListString', names);
                if ~ok
                    return;
                end
                app.awaitTask(app.host.ApplyProtocolPresetAsync(names{idx}));
                app.refreshProtocolPropertyGrid();
                app.refreshAcquireControls();
            catch ex
                app.showError(ex.message, 'Protocol Presets Error');
            end
        end

        function configureInitializeRigSelected(app, ~)
            try
                rigs = app.awaitTaskWithResult(app.host.GetAvailableRigDescriptionsAsync());
                n = SymphonyAppUtil.getNetCount(rigs);
                if n == 0
                    uialert(app.UIFigure, 'No rigs available.', 'Initialize Rig');
                    return;
                end
                labels = cell(1, n);
                ids = cell(1, n);
                for i = 1:n
                    r = SymphonyAppUtil.getNetItem(rigs, i);
                    labels{i} = char(r.DisplayName);
                    ids{i} = char(r.Id);
                end
                [idx, ok] = listdlg('PromptString', 'Select rig:', 'SelectionMode', 'single', 'ListString', labels);
                if ~ok
                    return;
                end
                app.awaitTask(app.host.InitializeRigAsync(ids{idx}));
                app.refreshAcquireControls();
            catch ex
                app.showError(ex.message, 'Initialize Rig Error');
            end
        end

        function configureDevicesSelected(app, ~)
            uialert(app.UIFigure, 'Configure Devices is not implemented in this C# host-backed UI yet.', 'Not Implemented');
        end

        function configureOptionsSelected(app, ~)
            try
                symphonyui.ui.SymphonyOptionsDialog.showBlocking(app.UIFigure);
            catch ex
                app.showError(ex.message, 'Options');
            end
        end

        function modulesRefreshSelected(app, ~)
            uialert(app.UIFigure, 'Modules are not implemented in this C# host-backed UI yet.', 'Modules');
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
            msg = sprintf('SymphonyAppMinimal\nC# host-backed MATLAB UI');
            uialert(app.UIFigure, msg, 'About SymphonyAppMinimal');
        end

        function recordButtonPushed(app, ~)
            try
                app.awaitTask(app.host.RecordAsync());
            catch ex
                app.showError(ex.message, 'Record Error');
            end
            app.refreshAcquireControls();
        end

        function pauseButtonPushed(app, ~)
            try
                app.awaitTask(app.host.RequestPauseAsync());
            catch ex
                app.showError(ex.message, 'Pause Error');
            end
            app.refreshAcquireControls();
        end

        function stopAndDeleteButtonPushed(app, ~)
            try
                app.awaitTask(app.host.RequestStopAsync());
            catch ex
                app.showError(ex.message, 'Stop Error');
            end
            app.refreshAcquireControls();
        end

        function refreshAcquireControls(app)
            try
                state = app.awaitTaskWithResult(app.host.GetControllerStateAsync());
                stateName = char(state.ToString());

                expState = app.awaitTaskWithResult(app.host.GetExperimentStateAsync());
                hasEpochGroup = logical(expState.HasEpochGroup);

                validation = app.awaitTaskWithResult(app.host.ValidateProtocolAsync());
                isValid = logical(validation.IsValid);

                isStopped = strcmp(stateName, 'Stopped');
                isStopping = strcmp(stateName, 'Stopping');
                isPausing = strcmp(stateName, 'Pausing');
                isViewingPaused = strcmp(stateName, 'ViewingPaused');
                isRecordingPaused = strcmp(stateName, 'RecordingPaused');

                app.viewOnlyButton.Enable = SymphonyAppUtil.onOff(isValid && (isViewingPaused || isStopped));
                app.recordButton.Enable = SymphonyAppUtil.onOff(isValid && hasEpochGroup && (isRecordingPaused || isStopped));
                app.pauseButton.Enable = SymphonyAppUtil.onOff(~isPausing && ~isViewingPaused && ~isRecordingPaused && ~isStopping && ~isStopped);
                app.stopAndDeleteButton.Enable = SymphonyAppUtil.onOff(~isStopping && ~isStopped);

                if ~isValid
                    m = char(validation.Message);
                    if isempty(m); m = 'Invalid protocol'; end
                    app.statusLabel.Text = ['Status: ' m];
                else
                    app.statusLabel.Text = ['Status: ' stateName];
                end
            catch ex
                app.showError(ex.message, 'State Update Error');
            end
        end

        function awaitTask(app, task) %#ok<INUSL>
            task.GetAwaiter().GetResult();
        end

        function result = awaitTaskWithResult(app, task) %#ok<INUSL>
            result = task.GetAwaiter().GetResult();
        end

        function showError(app, msg, title)
            if nargin < 3
                title = 'Error';
            end
            try
                uialert(app.UIFigure, char(msg), title);
            catch
                disp(msg);
            end
        end

        function createComponents(app)
            app.UIFigure = uifigure('Visible', 'off');
            app.UIFigure.Position = [100 100 390 560];
            app.UIFigure.Name = 'SymphonyAppMinimal';

            app.fileMenu = uimenu(app.UIFigure, 'Text', 'File');
            app.documentMenu = uimenu(app.UIFigure, 'Text', 'Document');
            app.AcquireMenu = uimenu(app.UIFigure, 'Text', 'Acquire');
            app.ConfigureMenu = uimenu(app.UIFigure, 'Text', 'Configure');
            app.ModulesMenu = uimenu(app.UIFigure, 'Text', 'Modules');
            app.HelpMenu = uimenu(app.UIFigure, 'Text', 'Help');

            uimenu(app.fileMenu, 'Text', 'New...   Ctrl+N', 'MenuSelectedFcn', createCallbackFcn(app, @fileNewSelected, true));
            uimenu(app.fileMenu, 'Text', 'Open...   Ctrl+O', 'MenuSelectedFcn', createCallbackFcn(app, @fileOpenSelected, true));
            uimenu(app.fileMenu, 'Text', 'Close', 'MenuSelectedFcn', createCallbackFcn(app, @fileCloseSelected, true));
            uimenu(app.fileMenu, 'Text', 'Exit', 'Separator', 'on', 'MenuSelectedFcn', createCallbackFcn(app, @fileExitSelected, true));

            uimenu(app.documentMenu, 'Text', 'Add Source...', 'MenuSelectedFcn', createCallbackFcn(app, @documentAddSourceSelected, true));
            uimenu(app.documentMenu, 'Text', 'Begin Epoch Group...', 'Separator', 'on', 'MenuSelectedFcn', createCallbackFcn(app, @documentBeginEpochGroupSelected, true));
            uimenu(app.documentMenu, 'Text', 'End Epoch Group', 'MenuSelectedFcn', createCallbackFcn(app, @documentEndEpochGroupSelected, true));
            uimenu(app.documentMenu, 'Text', 'Add Note to Experiment...   Ctrl+T', 'Separator', 'on', 'MenuSelectedFcn', createCallbackFcn(app, @documentAddNoteSelected, true));

            uimenu(app.AcquireMenu, 'Text', 'View Only', 'MenuSelectedFcn', createCallbackFcn(app, @acquireViewOnlySelected, true));
            uimenu(app.AcquireMenu, 'Text', 'Record', 'MenuSelectedFcn', createCallbackFcn(app, @acquireRecordSelected, true));
            uimenu(app.AcquireMenu, 'Text', 'Pause', 'MenuSelectedFcn', createCallbackFcn(app, @acquirePauseSelected, true));
            uimenu(app.AcquireMenu, 'Text', 'Stop', 'MenuSelectedFcn', createCallbackFcn(app, @acquireStopSelected, true));
            uimenu(app.AcquireMenu, 'Text', 'Reset Protocol', 'Separator', 'on', 'MenuSelectedFcn', createCallbackFcn(app, @acquireResetProtocolSelected, true));
            uimenu(app.AcquireMenu, 'Text', 'Protocol Presets', 'MenuSelectedFcn', createCallbackFcn(app, @acquireProtocolPresetsSelected, true));

            uimenu(app.ConfigureMenu, 'Text', 'Initialize Rig...', 'MenuSelectedFcn', createCallbackFcn(app, @configureInitializeRigSelected, true));
            uimenu(app.ConfigureMenu, 'Text', 'Devices', 'MenuSelectedFcn', createCallbackFcn(app, @configureDevicesSelected, true));
            uimenu(app.ConfigureMenu, 'Text', 'Options', 'Separator', 'on', 'MenuSelectedFcn', createCallbackFcn(app, @configureOptionsSelected, true));

            uimenu(app.ModulesMenu, 'Text', 'Manage Modules...', 'MenuSelectedFcn', createCallbackFcn(app, @modulesRefreshSelected, true));

            uimenu(app.HelpMenu, 'Text', 'Documentation', 'MenuSelectedFcn', createCallbackFcn(app, @helpDocumentationSelected, true));
            uimenu(app.HelpMenu, 'Text', 'User Group', 'MenuSelectedFcn', createCallbackFcn(app, @helpUserGroupSelected, true));
            uimenu(app.HelpMenu, 'Text', 'About SymphonyAppMinimal', 'Separator', 'on', 'MenuSelectedFcn', createCallbackFcn(app, @helpAboutSelected, true));

            app.ProtocolDropDownLabel = uilabel(app.UIFigure);
            app.ProtocolDropDownLabel.HorizontalAlignment = 'right';
            app.ProtocolDropDownLabel.Position = [7 528 48 22];
            app.ProtocolDropDownLabel.Text = 'Protocol';

            app.protocolPopupMenu = uidropdown(app.UIFigure);
            app.protocolPopupMenu.Position = [68 528 312 22];
            app.protocolPopupMenu.ValueChangedFcn = createCallbackFcn(app, @protocolPopupMenuValueChanged, true);

            app.protocolPanel = uipanel(app.UIFigure);
            app.protocolPanel.Title = 'Protocol';
            app.protocolPanel.Position = [10 106 370 415];
            app.protocolPanel.BackgroundColor = [1 1 1];

            layout = uigridlayout(app.protocolPanel, [2 1]);
            layout.RowHeight = {'1x', 140};
            layout.ColumnWidth = {'1x'};
            layout.Padding = [5 5 5 5];
            layout.RowSpacing = 5;

            app.protocolPropertyGrid = uitable(layout);
            app.protocolPropertyGrid.ColumnName = {'Property', 'Value'};
            app.protocolPropertyGrid.ColumnEditable = [false true];
            app.protocolPropertyGrid.RowName = {};
            app.protocolPropertyGrid.CellEditCallback = createCallbackFcn(app, @protocolPropertyGridChanged, true);
            app.protocolPropertyGrid.Layout.Row = 1;

            app.protocolPreviewPanel = uipanel(layout);
            app.protocolPreviewPanel.Title = 'Preview';
            app.protocolPreviewPanel.BackgroundColor = [1 1 1];
            app.protocolPreviewPanel.Layout.Row = 2;

            app.viewOnlyButton = uibutton(app.UIFigure, 'push');
            app.viewOnlyButton.Tooltip = {'View Only'};
            app.viewOnlyButton.Position = [10 52 90 45];
            app.viewOnlyButton.Text = 'View Only';
            app.viewOnlyButton.ButtonPushedFcn = createCallbackFcn(app, @viewOnlyButtonPushed, true);

            app.recordButton = uibutton(app.UIFigure, 'push');
            app.recordButton.Tooltip = {'Record'};
            app.recordButton.Position = [105 52 90 45];
            app.recordButton.Text = 'Record';
            app.recordButton.ButtonPushedFcn = createCallbackFcn(app, @recordButtonPushed, true);

            app.pauseButton = uibutton(app.UIFigure, 'push');
            app.pauseButton.Tooltip = {'Pause'};
            app.pauseButton.Position = [200 52 90 45];
            app.pauseButton.Text = 'Pause';
            app.pauseButton.ButtonPushedFcn = createCallbackFcn(app, @pauseButtonPushed, true);

            app.stopAndDeleteButton = uibutton(app.UIFigure, 'push');
            app.stopAndDeleteButton.Tooltip = {'Stop'};
            app.stopAndDeleteButton.Position = [295 52 85 45];
            app.stopAndDeleteButton.Text = 'Stop';
            app.stopAndDeleteButton.ButtonPushedFcn = createCallbackFcn(app, @stopAndDeleteButtonPushed, true);

            app.statusLabel = uilabel(app.UIFigure);
            app.statusLabel.Position = [10 20 370 22];
            app.statusLabel.Text = 'Status: Stopped';

            app.UIFigure.WindowKeyPressFcn = createCallbackFcn(app, @onWindowKeyPress, true);

            app.UIFigure.Visible = 'on';
        end
    end

    methods (Access = public)
        function app = SymphonyAppMinimal
            createComponents(app);
            registerApp(app, app.UIFigure);
            runStartupFcn(app, @startupFcn);

            if nargout == 0
                clear app
            end
        end

        function delete(app)
            try
                if ~isempty(app.host)
                    app.awaitTask(app.host.ShutdownAsync());
                end
            catch
            end
            if isvalid(app.UIFigure)
                delete(app.UIFigure);
            end
        end
    end
end
