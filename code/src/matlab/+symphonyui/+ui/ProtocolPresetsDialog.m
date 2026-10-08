classdef ProtocolPresetsDialog < handle
    %PROTOCOLPRESETSDIALOG  Acquire → Protocol Presets (uifigure non-modal dialog).
    %   Lists saved protocol presets and allows the user to add, apply,
    %   update, or remove them.  Presets are stored using MATLAB preferences
    %   and managed entirely on the MATLAB side (no C# host dependency).

    properties (Access = private)
        fig matlab.ui.Figure
        parentFigure
        result  % preset name that was applied, or [] if closed without applying

        % Callback to get the current MATLAB protocol from the app
        getProtocolFcn  % function_handle returning the current Protocol object
        % Callback to apply a preset's properties to the app
        applyPresetFcn  % function_handle(protocolId, propertyMap)
        % Callbacks to run View Only / Record from the app
        viewOnlyFcn     % function_handle() to start View Only
        recordFcn       % function_handle() to start Record
        canRecordFcn    % function_handle() returning true if Record is allowed
        refreshTimer    % timer that periodically re-evaluates button states

        searchField matlab.ui.control.EditField
        presetList matlab.ui.control.ListBox
        allDisplayItems cell    % unfiltered display strings
        allItemsData cell       % unfiltered preset names (keys)
        addButton matlab.ui.control.Button
        applyButton matlab.ui.control.Button
        updateButton matlab.ui.control.Button
        removeButton matlab.ui.control.Button
        viewOnlyButton matlab.ui.control.Button
        recordButton matlab.ui.control.Button
        closeButton matlab.ui.control.Button
    end

    properties (Constant, Access = private)
        PREF_GROUP = 'SymphonyProtocolPresets'
        PREF_KEY = 'presets'
    end

    methods (Static)
        function result = showBlocking(parentFigure, getProtocolFcn, applyPresetFcn, viewOnlyFcn, recordFcn, canRecordFcn)
            %SHOWBLOCKING  Open Protocol Presets dialog and block until done.
            if nargin < 4, viewOnlyFcn = []; end
            if nargin < 5, recordFcn = []; end
            if nargin < 6, canRecordFcn = []; end
            dlg = symphonyui.ui.ProtocolPresetsDialog(parentFigure, getProtocolFcn, applyPresetFcn, viewOnlyFcn, recordFcn, canRecordFcn);
            dlg.fig.Visible = 'on';
            uiwait(dlg.fig);
            result = dlg.result;
        end

        function show(parentFigure, getProtocolFcn, applyPresetFcn, viewOnlyFcn, recordFcn, canRecordFcn)
            %SHOW  Open Protocol Presets dialog non-modally (non-blocking).
            if nargin < 4, viewOnlyFcn = []; end
            if nargin < 5, recordFcn = []; end
            if nargin < 6, canRecordFcn = []; end
            dlg = symphonyui.ui.ProtocolPresetsDialog(parentFigure, getProtocolFcn, applyPresetFcn, viewOnlyFcn, recordFcn, canRecordFcn);
            dlg.fig.Visible = 'on';
        end

        function timerRefresh(src, obj)
            % Refresh-timer callback (see constructor). Stops and deletes the
            % timer when the dialog or its figure is gone, or when a refresh
            % fails (e.g. the owning app was closed).
            try
                if isvalid(obj) && ~isempty(obj.fig) && isvalid(obj.fig)
                    obj.updateButtons();
                    return;
                end
            catch
            end
            try stop(src); catch, end
            try delete(src); catch, end
            if isvalid(obj)
                obj.refreshTimer = [];
            end
        end
    end

    methods (Access = private)
        function obj = ProtocolPresetsDialog(parentFigure, getProtocolFcn, applyPresetFcn, viewOnlyFcn, recordFcn, canRecordFcn)
            obj.parentFigure = parentFigure;
            obj.getProtocolFcn = getProtocolFcn;
            obj.applyPresetFcn = applyPresetFcn;
            obj.viewOnlyFcn = viewOnlyFcn;
            obj.recordFcn = recordFcn;
            obj.canRecordFcn = canRecordFcn;
            obj.result = [];
            obj.buildUi();
            obj.populate();
            obj.updateButtons();

            % Periodically refresh button states so Record enables/disables
            % when epoch groups are opened/closed externally.
            % The callback goes through a static method that receives the
            % timer itself, so it can stop the timer even after this dialog
            % object has been deleted (an instance call would error with
            % "Invalid or deleted object" inside the TimerFcn).
            obj.refreshTimer = timer( ...
                'ExecutionMode', 'fixedSpacing', ...
                'Period', 2, ...
                'Name', 'ProtocolPresetsRefresh', ...
                'Tag', 'ProtocolPresetsRefresh', ...
                'TimerFcn', @(src,~)symphonyui.ui.ProtocolPresetsDialog.timerRefresh(src, obj));
            start(obj.refreshTimer);
        end

        function buildUi(obj)
            % w = 380;
            % h = 280;
            % pos = obj.centerOnParent(w, h);
            pos = appbox.screenCenter(300,550);

            obj.fig = uifigure( ...
                'Name', 'Protocol Presets', ...
                'Position', pos, ...
                'Color', [0.94 0.94 0.94], ...
                'Resize', 'on', ...
                'CloseRequestFcn', @(~,~)obj.onClose(), ...
                'KeyPressFcn', @(~,e)obj.onKeyPress(e));
            symphonyui.ui.ViewSettings.installAutoSave(obj.fig, 'ProtocolPresets');

            main = uigridlayout(obj.fig, [2 2]);
            main.RowHeight = {22, '1x'};
            main.ColumnWidth = {'1x', 90};
            main.Padding = [12 12 12 12];
            main.ColumnSpacing = 8;
            main.RowSpacing = 4;

            % Search field for filtering presets
            obj.searchField = uieditfield(main, ...
                'Placeholder', 'Type here to filter presets', ...
                'ValueChangingFcn', @(~,e)obj.filterPresets(e.Value), ...
                'ValueChangedFcn', @(~,~)obj.filterPresets());
            obj.searchField.Layout.Row = 1;
            obj.searchField.Layout.Column = 1;

            % Left: preset list
            obj.presetList = uilistbox(main, ...
                'Items', {}, ...
                'Multiselect', 'off', ...
                'ValueChangedFcn', @(~,~)obj.updateButtons());
            obj.presetList.Layout.Row = 2;
            obj.presetList.Layout.Column = 1;
            % Double-click to apply preset (R2022a+)
            try
                obj.presetList.DoubleClickedFcn = @(~,~)obj.onApply();
            catch
            end

            % Right: buttons
            btnGrid = uigridlayout(main, [11 1]);
            btnGrid.Layout.Row = [1 2];
            btnGrid.Layout.Column = 2;
            btnGrid.RowHeight = {30, 30, 30, 30, 10, 30, 30, 10, 30, 30, '1x'};
            btnGrid.Padding = [0 0 0 0];
            btnGrid.RowSpacing = 4;

            % Get the path to the icons directory.
            appRoot = symphonyui.ui.symphonyAppRoot();
            iconPath = fullfile(appRoot, 'code', 'src', 'resources', 'icons');

            obj.applyButton = uibutton(btnGrid, ...
                'Tooltip', {'Apply Preset','To Main Viewer'}, ...
                'Text', 'Apply', ...
                'ButtonPushedFcn', @(~,~)obj.onApply());
            obj.updateButton = uibutton(btnGrid, ...
                'Tooltip', {'Update Preset','From Main Viewer'}, ...
                'Text', 'Update', ...
                'ButtonPushedFcn', @(~,~)obj.onUpdate());
            obj.addButton = uibutton(btnGrid, ...
                'Icon',fullfile(iconPath, 'add.png'),...
                'Text', '', ...
                'Tooltip', {'Add New Preset'}, ...
                'ButtonPushedFcn', @(~,~)obj.onAdd());
            obj.removeButton = uibutton(btnGrid, ...
                'Icon',fullfile(iconPath, 'remove.png'),...
                'Tooltip', {'Remove Preset'}, ...
                'Text', '', ...
                'ButtonPushedFcn', @(~,~)obj.onRemove());

            % Separator
            uilabel(btnGrid, 'Text', '');

            
            % iconPath = fullfile(pathToRoot, 'code', 'src', 'resources', 'icons');
            % View Only / Record — apply the selected preset then run
            obj.viewOnlyButton = uibutton(btnGrid,...
                'Icon',fullfile(iconPath, 'view_only_big.png'),...
                'Tooltip', {'View Only'}, ...
                'Text', '', ...
                'ButtonPushedFcn', @(~,~)obj.onViewOnly());
            obj.recordButton = uibutton(btnGrid,...
                'Icon',fullfile(iconPath, 'record_big.png'),...
                'Tooltip', {'Record'}, ...
                'Text', '', ...
                'ButtonPushedFcn', @(~,~)obj.onRecord());

            % Separator before Import/Export
            uilabel(btnGrid, 'Text', '');

            % Import/Export
            uibutton(btnGrid, ...
                'Text', 'Export...', ...
                'Tooltip', 'Export selected presets to a file', ...
                'ButtonPushedFcn', @(~,~)obj.onExport());
            uibutton(btnGrid, ...
                'Text', 'Import...', ...
                'Tooltip', 'Import presets from a file', ...
                'ButtonPushedFcn', @(~,~)obj.onImport());

            uilabel(btnGrid, 'Text', '');  % spacer

            symphonyui.ui.DialogUtil.setKeyPressFcnRecursive(obj.fig, @(~,e)obj.onKeyPress(e));
        end

        function populate(obj)
            presets = obj.loadPresets();
            if isempty(presets)
                obj.allDisplayItems = {};
                obj.allItemsData = {};
            else
                names = sort(presets.keys);
                displayItems = cell(size(names));
                for i = 1:numel(names)
                    p = presets(names{i});
                    protocolParts = strsplit(p.protocolId, '.');
                    protocolShort = protocolParts{end};
                    displayItems{i} = sprintf('%s (%s)', names{i}, protocolShort);
                end
                obj.allDisplayItems = displayItems;
                obj.allItemsData = names;
            end
            obj.filterPresets();
        end

        function filterPresets(obj, query)
            if nargin < 2
                query = obj.searchField.Value;
            end
            query = strtrim(query);
            if isempty(query)
                obj.presetList.Items = obj.allDisplayItems;
                obj.presetList.ItemsData = obj.allItemsData;
            else
                match = cellfun(@(s) contains(s, query, 'IgnoreCase', true), obj.allDisplayItems);
                obj.presetList.Items = obj.allDisplayItems(match);
                obj.presetList.ItemsData = obj.allItemsData(match);
            end
            obj.updateButtons();
        end

        function updateButtons(obj)
            hasSelection = ~isempty(obj.presetList.Items) && ...
                ~isempty(obj.presetList.Value);
            onOff = 'off';
            if hasSelection, onOff = 'on'; end
            obj.applyButton.Enable = onOff;
            obj.updateButton.Enable = onOff;
            obj.removeButton.Enable = onOff;

            % View Only requires a selection and callback
            hasViewOnly = hasSelection && ~isempty(obj.viewOnlyFcn);
            if hasViewOnly, obj.viewOnlyButton.Enable = 'on'; else, obj.viewOnlyButton.Enable = 'off'; end

            % Record also requires an open epoch group
            canRecord = hasSelection && ~isempty(obj.recordFcn);
            if canRecord && ~isempty(obj.canRecordFcn)
                try
                    canRecord = canRecord && logical(obj.canRecordFcn());
                catch
                    canRecord = false;
                end
            end
            if canRecord, obj.recordButton.Enable = 'on'; else, obj.recordButton.Enable = 'off'; end
        end

        function onAdd(obj)
            protocol = obj.getProtocolFcn();
            if isempty(protocol)
                uialert(obj.fig, 'Select a protocol first.', 'Add Preset');
                return;
            end

            answer = inputdlg('Preset name:', 'Add Protocol Preset', [1 40]);
            if isempty(answer) || isempty(strtrim(answer{1}))
                return;
            end
            name = strtrim(answer{1});

            try
                protocolId = class(protocol);
                propMap = protocol.getPropertyMap();

                presets = obj.loadPresets();
                preset.protocolId = protocolId;
                preset.propertyMap = propMap;
                presets(name) = preset; %#ok<NASGU>
                obj.savePresets(presets);

                obj.searchField.Value = '';
                obj.populate();
                obj.presetList.Value = name;
                obj.updateButtons();
            catch ex
                fprintf(2, 'ProtocolPresetsDialog: add failed: %s\n', ex.message);
                uialert(obj.fig, ex.message, 'Add Preset Error');
            end
        end

        function onApply(obj)
            name = obj.presetList.Value;
            if isempty(name)
                return;
            end
            try
                presets = obj.loadPresets();
                if ~presets.isKey(name)
                    uialert(obj.fig, 'Preset not found.', 'Apply Preset');
                    return;
                end
                preset = presets(name);
                obj.applyPresetFcn(preset.protocolId, preset.propertyMap);
                obj.result = name;
            catch ex
                fprintf(2, 'ProtocolPresetsDialog: apply failed: %s\n', ex.message);
                uialert(obj.fig, ex.message, 'Apply Preset Error');
            end
        end

        function onUpdate(obj)
            name = obj.presetList.Value;
            if isempty(name)
                return;
            end
            protocol = obj.getProtocolFcn();
            if isempty(protocol)
                uialert(obj.fig, 'Select a protocol first.', 'Update Preset');
                return;
            end
            try
                presets = obj.loadPresets();
                preset.protocolId = class(protocol);
                preset.propertyMap = protocol.getPropertyMap();
                presets(name) = preset; %#ok<NASGU>
                obj.savePresets(presets);
            catch ex
                fprintf(2, 'ProtocolPresetsDialog: update failed: %s\n', ex.message);
                uialert(obj.fig, ex.message, 'Update Preset Error');
            end
        end

        function onRemove(obj)
            name = obj.presetList.Value;
            if isempty(name)
                return;
            end
            try
                presets = obj.loadPresets();
                if presets.isKey(name)
                    presets.remove(name);
                end
                obj.savePresets(presets);
                obj.populate();
                obj.updateButtons();
            catch ex
                fprintf(2, 'ProtocolPresetsDialog: remove failed: %s\n', ex.message);
                uialert(obj.fig, ex.message, 'Remove Preset Error');
            end
        end

        function onViewOnly(obj)
            % Apply the selected preset, then start View Only
            obj.onApply();
            if ~isempty(obj.result) && ~isempty(obj.viewOnlyFcn)
                try
                    obj.viewOnlyFcn();
                catch ex
                    fprintf(2, 'ProtocolPresetsDialog: view only failed: %s\n', ex.message);
                    uialert(obj.fig, ex.message, 'View Only Error');
                end
            end
        end

        function onRecord(obj)
            % Apply the selected preset, then start Record
            obj.onApply();
            if ~isempty(obj.result) && ~isempty(obj.recordFcn)
                try
                    obj.recordFcn();
                catch ex
                    fprintf(2, 'ProtocolPresetsDialog: record failed: %s\n', ex.message);
                    uialert(obj.fig, ex.message, 'Record Error');
                end
            end
        end

        function onExport(obj)
            % Export selected presets to a .mat file.
            allPresets = obj.loadPresets();
            if isempty(allPresets) || allPresets.Count == 0
                uialert(obj.fig, 'No presets to export.', 'Export Presets');
                return;
            end

            allNames = sort(allPresets.keys);

            % Show selection dialog
            [sel, ok] = listdlg( ...
                'ListString', allNames, ...
                'SelectionMode', 'multiple', ...
                'InitialValue', 1:numel(allNames), ...
                'Name', 'Export Presets', ...
                'PromptString', 'Select presets to export:', ...
                'ListSize', [300, 250]);
            if ~ok || isempty(sel)
                return;
            end

            selectedNames = allNames(sel);

            % Get default save location from Options
            defaultDir = pwd;
            try
                opts = symphonyui.app.Options.getDefault();
                loc = opts.fileDefaultLocation;
                if isa(loc, 'function_handle'), loc = loc(); end
                loc = char(loc);
                if isfolder(loc), defaultDir = loc; end
            catch
            end

            [filename, pathname] = uiputfile( ...
                {'*.mat', 'MATLAB Preset Files (*.mat)'}, ...
                'Export Presets', ...
                fullfile(defaultDir, 'symphony_presets.mat'));
            if isequal(filename, 0)
                return;
            end

            % Build export struct
            exportData = struct();
            exportData.version = 1;
            exportData.exportDate = datestr(now);
            exportData.presets = containers.Map();
            for i = 1:numel(selectedNames)
                exportData.presets(selectedNames{i}) = allPresets(selectedNames{i});
            end

            try
                save(fullfile(pathname, filename), '-struct', 'exportData');
                fprintf('Exported %d presets to %s\n', numel(selectedNames), fullfile(pathname, filename));
            catch ex
                uialert(obj.fig, ex.message, 'Export Error');
            end
        end

        function onImport(obj)
            % Import presets from a .mat file.

            % Get default location from Options
            defaultDir = pwd;
            try
                opts = symphonyui.app.Options.getDefault();
                loc = opts.fileDefaultLocation;
                if isa(loc, 'function_handle'), loc = loc(); end
                loc = char(loc);
                if isfolder(loc), defaultDir = loc; end
            catch
            end

            [filename, pathname] = uigetfile( ...
                {'*.mat', 'MATLAB Preset Files (*.mat)'}, ...
                'Import Presets', defaultDir);
            if isequal(filename, 0)
                return;
            end

            filepath = fullfile(pathname, filename);
            try
                importData = load(filepath);
            catch ex
                uialert(obj.fig, ['Failed to load file: ' ex.message], 'Import Error');
                return;
            end

            % Validate
            if ~isfield(importData, 'presets') || ~isa(importData.presets, 'containers.Map')
                uialert(obj.fig, 'File does not contain valid Symphony presets.', 'Import Error');
                return;
            end

            importNames = sort(importData.presets.keys);
            if isempty(importNames)
                uialert(obj.fig, 'No presets found in file.', 'Import Error');
                return;
            end

            % Show selection dialog
            [sel, ok] = listdlg( ...
                'ListString', importNames, ...
                'SelectionMode', 'multiple', ...
                'InitialValue', 1:numel(importNames), ...
                'Name', 'Import Presets', ...
                'PromptString', 'Select presets to import:', ...
                'ListSize', [300, 250]);
            if ~ok || isempty(sel)
                return;
            end

            selectedNames = importNames(sel);

            % Check for conflicts with existing presets
            existingPresets = obj.loadPresets();
            if isempty(existingPresets)
                existingPresets = containers.Map();
            end

            conflicts = {};
            for i = 1:numel(selectedNames)
                if existingPresets.isKey(selectedNames{i})
                    conflicts{end+1} = selectedNames{i}; %#ok<AGROW>
                end
            end

            if ~isempty(conflicts)
                answer = uiconfirm(obj.fig, ...
                    sprintf('The following presets already exist:\n\n%s\n\nOverwrite them?', ...
                        strjoin(conflicts, '\n')), ...
                    'Import Conflict', ...
                    'Options', {'Overwrite', 'Skip Conflicts', 'Cancel'}, ...
                    'DefaultOption', 2, 'CancelOption', 3);
                switch answer
                    case 'Cancel'
                        return;
                    case 'Skip Conflicts'
                        selectedNames = setdiff(selectedNames, conflicts);
                        if isempty(selectedNames)
                            return;
                        end
                end
            end

            % Import selected presets
            imported = 0;
            for i = 1:numel(selectedNames)
                name = selectedNames{i};
                presetData = importData.presets(name);
                existingPresets(name) = presetData;
                imported = imported + 1;
            end

            % Save back
            try
                obj.savePresets(existingPresets);
                fprintf('Imported %d presets from %s\n', imported, filepath);
                obj.populate();
                obj.updateButtons();
            catch ex
                uialert(obj.fig, ex.message, 'Import Error');
            end
        end

        function onClose(obj)
            obj.stopTimer();
            obj.closeDialog();
        end

        function onKeyPress(obj, event)
            switch event.Key
                case 'escape'
                    obj.onClose();
                case 'return'
                    if ~isempty(obj.presetList.Value)
                        obj.onApply();
                    end
            end
        end

        function onTimerRefresh(obj)
            try
                if ~isvalid(obj) || isempty(obj.fig) || ~isvalid(obj.fig)
                    obj.stopTimer();
                    return;
                end
                obj.updateButtons();
            catch
                obj.stopTimer();
            end
        end

        function stopTimer(obj)
            if ~isempty(obj.refreshTimer)
                try stop(obj.refreshTimer); catch, end
                try delete(obj.refreshTimer); catch, end
                obj.refreshTimer = [];
            end
        end

        function closeDialog(obj)
            obj.stopTimer();
            if isvalid(obj.fig)
                uiresume(obj.fig);
                delete(obj.fig);
            end
        end

        function pos = centerOnParent(obj, w, h)
            if ~isempty(obj.parentFigure) && isvalid(obj.parentFigure)
                pp = obj.parentFigure.Position;
                pos = [pp(1) + (pp(3) - w) / 2, pp(2) + (pp(4) - h) / 2, w, h];
            else
                pos = [100 100 w h];
            end
        end
    end

    methods (Static, Access = private)
        function presets = loadPresets()
            %LOADPRESETS  Load presets from MATLAB preferences.
            %   Returns a containers.Map of preset name -> struct(protocolId, propertyMap).
            presets = getpref(symphonyui.ui.ProtocolPresetsDialog.PREF_GROUP, ...
                symphonyui.ui.ProtocolPresetsDialog.PREF_KEY, containers.Map());
        end

        function savePresets(presets)
            %SAVEPRESETS  Save presets to MATLAB preferences.
            setpref(symphonyui.ui.ProtocolPresetsDialog.PREF_GROUP, ...
                symphonyui.ui.ProtocolPresetsDialog.PREF_KEY, presets);
        end
    end
end
