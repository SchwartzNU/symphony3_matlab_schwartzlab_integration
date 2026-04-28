classdef RigBuilderDialog < handle
    %RIGBUILDERDIALOG  Visual rig configuration builder.
    %   Lets users assemble a rig by picking a DAQ controller, adding devices,
    %   assigning streams, and configuring settings. Generates the .m class file.
    %
    %   Usage:
    %       symphonyui.ui.RigBuilderDialog.showBlocking(parentFigure)

    properties (Access = private)
        fig matlab.ui.Figure
        parentFigure

        % Data model
        rigConfig       % struct: daqType, className, packagePath, outputDir
        deviceList      % cell array of device structs
        assignedStreams  % containers.Map: stream name -> device name
        selectedIndex    % index into deviceList for the currently displayed device

        % Top bar
        classNameField matlab.ui.control.EditField
        packageField matlab.ui.control.EditField
        outputDirField matlab.ui.control.EditField

        % Left panel
        daqDropdown matlab.ui.control.DropDown
        daqArgsField matlab.ui.control.EditField
        daqArgsLabel matlab.ui.control.Label
        deviceListBox matlab.ui.control.ListBox

        % Right panel — device detail fields
        deviceTypeDropdown matlab.ui.control.DropDown
        deviceNameField matlab.ui.control.EditField
        deviceUnitsDropdown matlab.ui.control.DropDown
        channelSpinner matlab.ui.control.Spinner
        outputStreamDropdown matlab.ui.control.DropDown
        inputStreamDropdown matlab.ui.control.DropDown
        digitalPortDropdown matlab.ui.control.DropDown
        bitPositionSpinner matlab.ui.control.Spinner

        % Labels (for show/hide)
        channelLabel matlab.ui.control.Label
        unitsLabel matlab.ui.control.Label
        outputLabel matlab.ui.control.Label
        inputLabel matlab.ui.control.Label
        digitalLabel matlab.ui.control.Label
        bitLabel matlab.ui.control.Label

        % Configuration settings table
        configTable matlab.ui.control.Table

        % Right panel container for enable/disable
        rightPanel
    end

    % ================================================================
    % Static entry point
    % ================================================================
    methods (Static)
        function showBlocking(parentFigure)
            if nargin < 1, parentFigure = []; end
            dlg = symphonyui.ui.RigBuilderDialog(parentFigure);
            dlg.fig.Visible = 'on';
            uiwait(dlg.fig);
        end
    end

    % ================================================================
    % Construction & lifecycle
    % ================================================================
    methods (Access = private)

        function obj = RigBuilderDialog(parentFigure)
            obj.parentFigure = parentFigure;
            obj.deviceList = {};
            obj.assignedStreams = containers.Map();
            obj.selectedIndex = 0;
            obj.initDefaults();
            obj.buildUi();
        end

        function initDefaults(obj)
            obj.rigConfig = struct( ...
                'daqType', 'HekaDaqController', ...
                'daqArgs', '', ...
                'className', 'MyRig', ...
                'packagePath', '+my+rigs', ...
                'outputDir', pwd);
        end

        % ============================================================
        % UI Construction
        % ============================================================
        function buildUi(obj)
            w = 860; h = 620;
            pos = obj.centerOnParent(w, h);

            obj.fig = uifigure( ...
                'Name', 'Rig Builder', ...
                'Position', pos, ...
                'Resize', 'on', ...
                'Color', [0.94 0.94 0.94], ...
                'Visible', 'off', ...
                'CloseRequestFcn', @(~,~)obj.onCancel(), ...
                'KeyPressFcn', @(~,e)obj.onKeyPress(e));

            main = uigridlayout(obj.fig, [3 1]);
            main.RowHeight = {58, '1x', 40};
            main.Padding = [10 10 10 10];
            main.RowSpacing = 8;

            obj.buildTopBar(main);
            obj.buildPanes(main);
            obj.buildFooter(main);

            symphonyui.ui.DialogUtil.setKeyPressFcnRecursive(obj.fig, @(~,e)obj.onKeyPress(e));
            symphonyui.ui.ViewSettings.installAutoSave(obj.fig, 'RigBuilder');
        end

        function buildTopBar(obj, parent)
            top = uigridlayout(parent, [2 6]);
            top.Layout.Row = 1;
            top.RowHeight = {24, 24};
            top.ColumnWidth = {75, '1x', 75, '1x', 75, '1x'};
            top.Padding = [0 0 0 0];
            top.RowSpacing = 4;
            top.ColumnSpacing = 6;

            lbl = uilabel(top, 'Text', 'Class Name:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 1; lbl.Layout.Column = 1;
            obj.classNameField = uieditfield(top, 'text', 'Value', obj.rigConfig.className);
            obj.classNameField.Layout.Row = 1; obj.classNameField.Layout.Column = 2;

            lbl = uilabel(top, 'Text', 'Package:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 1; lbl.Layout.Column = 3;
            obj.packageField = uieditfield(top, 'text', 'Value', obj.rigConfig.packagePath, ...
                'Tooltip', 'MATLAB package path, e.g. +my+rigs');
            obj.packageField.Layout.Row = 1; obj.packageField.Layout.Column = 4;

            lbl = uilabel(top, 'Text', 'Output Dir:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 1; lbl.Layout.Column = 5;
            obj.outputDirField = uieditfield(top, 'text', 'Value', obj.rigConfig.outputDir);
            obj.outputDirField.Layout.Row = 1; obj.outputDirField.Layout.Column = 6;

            browseBtn = uibutton(top, 'Text', 'Browse...', 'ButtonPushedFcn', @(~,~)obj.onBrowseDir());
            browseBtn.Layout.Row = 2; browseBtn.Layout.Column = 6;
        end

        function buildPanes(obj, parent)
            panes = uigridlayout(parent, [1 2]);
            panes.Layout.Row = 2;
            panes.ColumnWidth = {210, '1x'};
            panes.Padding = [0 0 0 0];
            panes.ColumnSpacing = 8;

            obj.buildLeftPanel(panes);
            obj.buildRightPanel(panes);
        end

        function buildLeftPanel(obj, parent)
            left = uigridlayout(parent, [5 1]);
            left.Layout.Column = 1;
            left.RowHeight = {24, 24, 20, '1x', 28};
            left.Padding = [0 0 0 0];
            left.RowSpacing = 4;

            % DAQ type
            obj.daqDropdown = uidropdown(left, ...
                'Items', {'HekaDaqController', 'NiDaqController', ...
                          'HekaSimulationDaqController', 'NiSimulationDaqController'}, ...
                'Value', 'HekaDaqController', ...
                'ValueChangedFcn', @(~,~)obj.onDaqChanged());
            obj.daqDropdown.Layout.Row = 1;

            % NI device args (hidden unless NI selected)
            argsRow = uigridlayout(left, [1 2]);
            argsRow.Layout.Row = 2;
            argsRow.ColumnWidth = {55, '1x'};
            argsRow.Padding = [0 0 0 0];
            obj.daqArgsLabel = uilabel(argsRow, 'Text', 'NI Dev:', 'Visible', 'off');
            obj.daqArgsField = uieditfield(argsRow, 'text', 'Value', 'Dev1', 'Visible', 'off', ...
                'Tooltip', 'NI device name (e.g. Dev1)');

            % Label
            lbl = uilabel(left, 'Text', 'Devices:', 'FontWeight', 'bold');
            lbl.Layout.Row = 3;

            % Device list
            obj.deviceListBox = uilistbox(left, ...
                'Items', {}, ...
                'ValueChangedFcn', @(~,~)obj.onDeviceSelected());
            obj.deviceListBox.Layout.Row = 4;

            % Buttons
            btnRow = uigridlayout(left, [1 4]);
            btnRow.Layout.Row = 5;
            btnRow.ColumnWidth = {'1x', '1x', '1x', '1x'};
            btnRow.Padding = [0 0 0 0];
            btnRow.ColumnSpacing = 4;
            uibutton(btnRow, 'Text', '+ Add', 'ButtonPushedFcn', @(~,~)obj.onAddDevice());
            uibutton(btnRow, 'Text', '- Remove', 'ButtonPushedFcn', @(~,~)obj.onRemoveDevice());
            uibutton(btnRow, 'Text', char(9650), 'ButtonPushedFcn', @(~,~)obj.onMoveUp(), 'Tooltip', 'Move Up');
            uibutton(btnRow, 'Text', char(9660), 'ButtonPushedFcn', @(~,~)obj.onMoveDown(), 'Tooltip', 'Move Down');
        end

        function buildRightPanel(obj, parent)
            obj.rightPanel = uigridlayout(parent, [10 2]);
            obj.rightPanel.Layout.Column = 2;
            obj.rightPanel.RowHeight = {24, 24, 24, 24, 24, 24, 24, 24, 20, '1x'};
            obj.rightPanel.ColumnWidth = {100, '1x'};
            obj.rightPanel.Padding = [0 0 0 0];
            obj.rightPanel.RowSpacing = 4;
            obj.rightPanel.ColumnSpacing = 6;

            rp = obj.rightPanel;

            % Row 1: Type
            lbl = uilabel(rp, 'Text', 'Type:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 1; lbl.Layout.Column = 1;
            obj.deviceTypeDropdown = uidropdown(rp, ...
                'Items', {'MultiClampDevice', 'UnitConvertingDevice', 'CalibratedDevice', ...
                          'SimulatedAmplifierDevice'}, ...
                'Value', 'UnitConvertingDevice', ...
                'ValueChangedFcn', @(~,~)obj.onDeviceTypeChanged());
            obj.deviceTypeDropdown.Layout.Row = 1; obj.deviceTypeDropdown.Layout.Column = 2;

            % Row 2: Name
            lbl = uilabel(rp, 'Text', 'Name:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 2; lbl.Layout.Column = 1;
            obj.deviceNameField = uieditfield(rp, 'text', 'Value', '', ...
                'ValueChangedFcn', @(~,~)obj.onDeviceFieldChanged());
            obj.deviceNameField.Layout.Row = 2; obj.deviceNameField.Layout.Column = 2;

            % Row 3: Channel # (MultiClamp only)
            obj.channelLabel = uilabel(rp, 'Text', 'Channel #:', 'HorizontalAlignment', 'right');
            obj.channelLabel.Layout.Row = 3; obj.channelLabel.Layout.Column = 1;
            obj.channelSpinner = uispinner(rp, 'Value', 1, 'Limits', [1 8], 'Step', 1, ...
                'ValueChangedFcn', @(~,~)obj.onDeviceFieldChanged());
            obj.channelSpinner.Layout.Row = 3; obj.channelSpinner.Layout.Column = 2;

            % Row 4: Units (UnitConv/Calibrated only)
            obj.unitsLabel = uilabel(rp, 'Text', 'Units:', 'HorizontalAlignment', 'right');
            obj.unitsLabel.Layout.Row = 4; obj.unitsLabel.Layout.Column = 1;
            obj.deviceUnitsDropdown = uidropdown(rp, ...
                'Items', {'V', 'mV', 'pA', 'nA', 'A', 'UNITLESS', 'NORMALIZED'}, ...
                'Value', 'V', 'Editable', 'on', ...
                'ValueChangedFcn', @(~,~)obj.onDeviceFieldChanged());
            obj.deviceUnitsDropdown.Layout.Row = 4; obj.deviceUnitsDropdown.Layout.Column = 2;

            % Row 5: Output stream
            obj.outputLabel = uilabel(rp, 'Text', 'Output:', 'HorizontalAlignment', 'right');
            obj.outputLabel.Layout.Row = 5; obj.outputLabel.Layout.Column = 1;
            obj.outputStreamDropdown = uidropdown(rp, ...
                'Items', {'(none)'}, 'Value', '(none)', ...
                'ValueChangedFcn', @(~,~)obj.onDeviceFieldChanged());
            obj.outputStreamDropdown.Layout.Row = 5; obj.outputStreamDropdown.Layout.Column = 2;

            % Row 6: Input stream
            obj.inputLabel = uilabel(rp, 'Text', 'Input:', 'HorizontalAlignment', 'right');
            obj.inputLabel.Layout.Row = 6; obj.inputLabel.Layout.Column = 1;
            obj.inputStreamDropdown = uidropdown(rp, ...
                'Items', {'(none)'}, 'Value', '(none)', ...
                'ValueChangedFcn', @(~,~)obj.onDeviceFieldChanged());
            obj.inputStreamDropdown.Layout.Row = 6; obj.inputStreamDropdown.Layout.Column = 2;

            % Row 7: Digital port
            obj.digitalLabel = uilabel(rp, 'Text', 'Digital Port:', 'HorizontalAlignment', 'right');
            obj.digitalLabel.Layout.Row = 7; obj.digitalLabel.Layout.Column = 1;
            obj.digitalPortDropdown = uidropdown(rp, ...
                'Items', {'(none)'}, 'Value', '(none)', ...
                'ValueChangedFcn', @(~,~)obj.onDeviceFieldChanged());
            obj.digitalPortDropdown.Layout.Row = 7; obj.digitalPortDropdown.Layout.Column = 2;

            % Row 8: Bit position
            obj.bitLabel = uilabel(rp, 'Text', 'Bit Position:', 'HorizontalAlignment', 'right');
            obj.bitLabel.Layout.Row = 8; obj.bitLabel.Layout.Column = 1;
            obj.bitPositionSpinner = uispinner(rp, 'Value', 0, 'Limits', [0 15], 'Step', 1, ...
                'ValueChangedFcn', @(~,~)obj.onDeviceFieldChanged());
            obj.bitPositionSpinner.Layout.Row = 8; obj.bitPositionSpinner.Layout.Column = 2;

            % Row 9: Config label + buttons
            cfgRow = uigridlayout(rp, [1 3]);
            cfgRow.Layout.Row = 9; cfgRow.Layout.Column = [1 2];
            cfgRow.ColumnWidth = {'1x', 60, 60};
            cfgRow.Padding = [0 0 0 0];
            uilabel(cfgRow, 'Text', 'Config Settings:', 'FontWeight', 'bold');
            uibutton(cfgRow, 'Text', '+ Add', 'ButtonPushedFcn', @(~,~)obj.onAddConfig());
            uibutton(cfgRow, 'Text', '- Remove', 'ButtonPushedFcn', @(~,~)obj.onRemoveConfig());

            % Row 10: Config table
            obj.configTable = uitable(rp, ...
                'ColumnName', {'Setting', 'Default', 'Type', 'Domain'}, ...
                'ColumnEditable', [false false false false], ...
                'ColumnWidth', {'auto', 'auto', 'auto', '1x'});
            obj.configTable.Layout.Row = 10; obj.configTable.Layout.Column = [1 2];

            % Start with right panel disabled
            obj.setRightPanelEnabled(false);
        end

        function buildFooter(obj, parent)
            footer = uigridlayout(parent, [1 4]);
            footer.Layout.Row = 3;
            footer.ColumnWidth = {'1x', 110, 110, 80};
            footer.Padding = [0 0 0 0];
            footer.ColumnSpacing = 8;

            uilabel(footer, 'Text', '');  % spacer
            uibutton(footer, 'Text', 'Preview Code...', 'ButtonPushedFcn', @(~,~)obj.onPreviewCode());
            uibutton(footer, 'Text', 'Generate && Save', 'ButtonPushedFcn', @(~,~)obj.onGenerateAndSave());
            uibutton(footer, 'Text', 'Cancel', 'ButtonPushedFcn', @(~,~)obj.onCancel());
        end

        % ============================================================
        % DAQ handling
        % ============================================================
        function onDaqChanged(obj)
            daqType = obj.daqDropdown.Value;
            obj.rigConfig.daqType = daqType;

            isNi = contains(daqType, 'Ni');
            if isNi
                obj.daqArgsLabel.Visible = 'on';
                obj.daqArgsField.Visible = 'on';
            else
                obj.daqArgsLabel.Visible = 'off';
                obj.daqArgsField.Visible = 'off';
            end

            % Check for stream conflicts with existing devices
            allStreams = obj.getAllStreamsForCurrentDaq();
            for i = 1:numel(obj.deviceList)
                d = obj.deviceList{i};
                if ~isempty(d.outputStream) && ~ismember(d.outputStream, allStreams)
                    d.outputStream = '';
                end
                if ~isempty(d.inputStream) && ~ismember(d.inputStream, allStreams)
                    d.inputStream = '';
                end
                if ~isempty(d.digitalPort) && ~ismember(d.digitalPort, allStreams)
                    d.digitalPort = '';
                    d.bitPosition = -1;
                end
                obj.deviceList{i} = d;
            end
            obj.refreshStreamAssignments();
            obj.refreshDeviceListBox();
            if obj.selectedIndex > 0
                obj.loadDeviceToPanel(obj.selectedIndex);
            end
        end

        % ============================================================
        % Device list management
        % ============================================================
        function onAddDevice(obj)
            n = numel(obj.deviceList) + 1;
            d = obj.newDeviceStruct();
            d.name = sprintf('Device%d', n);
            d.type = 'UnitConvertingDevice';
            d.units = 'V';
            obj.deviceList{end+1} = d;
            obj.refreshDeviceListBox();
            obj.selectedIndex = numel(obj.deviceList);
            obj.deviceListBox.Value = obj.selectedIndex;
            obj.loadDeviceToPanel(obj.selectedIndex);
            obj.setRightPanelEnabled(true);
        end

        function onRemoveDevice(obj)
            if obj.selectedIndex < 1 || obj.selectedIndex > numel(obj.deviceList)
                return;
            end
            obj.deviceList(obj.selectedIndex) = [];
            obj.refreshStreamAssignments();
            if isempty(obj.deviceList)
                obj.selectedIndex = 0;
                obj.setRightPanelEnabled(false);
            else
                obj.selectedIndex = min(obj.selectedIndex, numel(obj.deviceList));
            end
            obj.refreshDeviceListBox();
            if obj.selectedIndex > 0
                obj.deviceListBox.Value = obj.selectedIndex;
                obj.loadDeviceToPanel(obj.selectedIndex);
            end
        end

        function onMoveUp(obj)
            if obj.selectedIndex <= 1, return; end
            i = obj.selectedIndex;
            obj.deviceList([i-1, i]) = obj.deviceList([i, i-1]);
            obj.selectedIndex = i - 1;
            obj.refreshDeviceListBox();
            obj.deviceListBox.Value = obj.selectedIndex;
        end

        function onMoveDown(obj)
            if obj.selectedIndex < 1 || obj.selectedIndex >= numel(obj.deviceList), return; end
            i = obj.selectedIndex;
            obj.deviceList([i, i+1]) = obj.deviceList([i+1, i]);
            obj.selectedIndex = i + 1;
            obj.refreshDeviceListBox();
            obj.deviceListBox.Value = obj.selectedIndex;
        end

        function onDeviceSelected(obj)
            if isempty(obj.deviceList)
                obj.selectedIndex = 0;
                obj.setRightPanelEnabled(false);
                return;
            end
            idx = obj.deviceListBox.Value;  % numeric via ItemsData
            if isempty(idx) || ~isnumeric(idx) || idx < 1 || idx > numel(obj.deviceList)
                return;
            end
            % Save current device before switching
            if obj.selectedIndex > 0 && obj.selectedIndex <= numel(obj.deviceList)
                obj.savePanelToDevice(obj.selectedIndex);
            end
            obj.selectedIndex = idx;
            obj.loadDeviceToPanel(idx);
            obj.setRightPanelEnabled(true);
        end

        function refreshDeviceListBox(obj)
            items = cell(1, numel(obj.deviceList));
            for i = 1:numel(obj.deviceList)
                d = obj.deviceList{i};
                items{i} = sprintf('%s (%s)', d.name, d.type);
            end
            obj.deviceListBox.Items = items;
            obj.deviceListBox.ItemsData = 1:numel(items);
        end

        % ============================================================
        % Right panel: load / save device
        % ============================================================
        function loadDeviceToPanel(obj, idx)
            d = obj.deviceList{idx};
            obj.deviceTypeDropdown.Value = d.type;
            obj.deviceNameField.Value = d.name;
            obj.channelSpinner.Value = max(1, d.channelNumber);
            obj.deviceUnitsDropdown.Value = d.units;
            obj.bitPositionSpinner.Value = max(0, d.bitPosition);

            obj.populateStreamDropdowns(d);
            obj.populateConfigTable(d);
            obj.updateFieldVisibility(d.type);
        end

        function savePanelToDevice(obj, idx)
            d = obj.deviceList{idx};
            d.name = obj.deviceNameField.Value;
            d.type = obj.deviceTypeDropdown.Value;
            d.channelNumber = obj.channelSpinner.Value;
            d.units = obj.deviceUnitsDropdown.Value;

            outVal = obj.outputStreamDropdown.Value;
            d.outputStream = obj.streamOrEmpty(outVal);
            inVal = obj.inputStreamDropdown.Value;
            d.inputStream = obj.streamOrEmpty(inVal);
            digVal = obj.digitalPortDropdown.Value;
            d.digitalPort = obj.streamOrEmpty(digVal);
            d.bitPosition = obj.bitPositionSpinner.Value;

            obj.deviceList{idx} = d;
            obj.refreshStreamAssignments();
            obj.refreshDeviceListBox();
            if idx <= numel(obj.deviceList)
                obj.deviceListBox.Value = idx;
            end
        end

        function onDeviceFieldChanged(obj)
            if obj.selectedIndex > 0 && obj.selectedIndex <= numel(obj.deviceList)
                obj.savePanelToDevice(obj.selectedIndex);
            end
        end

        function onDeviceTypeChanged(obj)
            newType = obj.deviceTypeDropdown.Value;
            obj.updateFieldVisibility(newType);
            obj.onDeviceFieldChanged();
        end

        function updateFieldVisibility(obj, devType)
            isMultiClamp = strcmp(devType, 'MultiClampDevice');
            isSimulated  = strcmp(devType, 'SimulatedAmplifierDevice');
            isUnitConv   = strcmp(devType, 'UnitConvertingDevice');
            isCalibrated = strcmp(devType, 'CalibratedDevice');
            hasStreams   = ~isSimulated;
            hasUnits     = isUnitConv || isCalibrated;
            hasDigital   = hasUnits;  % only generic devices get digital port

            obj.setVisible(obj.channelLabel, isMultiClamp);
            obj.setVisible(obj.channelSpinner, isMultiClamp);
            obj.setVisible(obj.unitsLabel, hasUnits);
            obj.setVisible(obj.deviceUnitsDropdown, hasUnits);
            obj.setVisible(obj.outputLabel, hasStreams);
            obj.setVisible(obj.outputStreamDropdown, hasStreams);
            obj.setVisible(obj.inputLabel, hasStreams);
            obj.setVisible(obj.inputStreamDropdown, hasStreams);
            obj.setVisible(obj.digitalLabel, hasDigital);
            obj.setVisible(obj.digitalPortDropdown, hasDigital);

            % Bit position only if a digital port is selected
            showBit = hasDigital && ~strcmp(obj.digitalPortDropdown.Value, '(none)');
            obj.setVisible(obj.bitLabel, showBit);
            obj.setVisible(obj.bitPositionSpinner, showBit);
        end

        % ============================================================
        % Stream management
        % ============================================================
        function populateStreamDropdowns(obj, currentDevice)
            streams = obj.getStreamsByCategory();

            % Output: ao* streams
            aoItems = [{'(none)'}, obj.filterAvailable(streams.ao, currentDevice.outputStream, currentDevice.name)];
            obj.outputStreamDropdown.Items = aoItems;
            if ismember(currentDevice.outputStream, aoItems)
                obj.outputStreamDropdown.Value = currentDevice.outputStream;
            else
                obj.outputStreamDropdown.Value = '(none)';
            end

            % Input: ai* streams
            aiItems = [{'(none)'}, obj.filterAvailable(streams.ai, currentDevice.inputStream, currentDevice.name)];
            obj.inputStreamDropdown.Items = aiItems;
            if ismember(currentDevice.inputStream, aiItems)
                obj.inputStreamDropdown.Value = currentDevice.inputStream;
            else
                obj.inputStreamDropdown.Value = '(none)';
            end

            % Digital: doport* streams
            doItems = [{'(none)'}, obj.filterAvailable(streams.doport, currentDevice.digitalPort, currentDevice.name)];
            obj.digitalPortDropdown.Items = doItems;
            if ismember(currentDevice.digitalPort, doItems)
                obj.digitalPortDropdown.Value = currentDevice.digitalPort;
            else
                obj.digitalPortDropdown.Value = '(none)';
            end
        end

        function available = filterAvailable(obj, allStreams, currentValue, deviceName)
            % Return streams not assigned to other devices, plus the current value
            available = {};
            for i = 1:numel(allStreams)
                s = allStreams{i};
                if obj.assignedStreams.isKey(s)
                    owner = obj.assignedStreams(s);
                    if strcmp(owner, deviceName) || strcmp(s, currentValue)
                        available{end+1} = s; %#ok<AGROW>
                    end
                    % else: assigned to another device, skip
                else
                    available{end+1} = s; %#ok<AGROW>
                end
            end
        end

        function refreshStreamAssignments(obj)
            obj.assignedStreams = containers.Map();
            for i = 1:numel(obj.deviceList)
                d = obj.deviceList{i};
                if ~isempty(d.outputStream)
                    obj.assignedStreams(d.outputStream) = d.name;
                end
                if ~isempty(d.inputStream)
                    obj.assignedStreams(d.inputStream) = d.name;
                end
                % Note: digital ports can be shared (multiple devices via bit positions)
            end
        end

        function streams = getStreamsByCategory(obj)
            daqType = obj.rigConfig.daqType;
            if contains(daqType, 'Heka')
                streams.ao = arrayfun(@(i) sprintf('ao%d',i), 0:7, 'UniformOutput', false);
                streams.ai = arrayfun(@(i) sprintf('ai%d',i), 0:15, 'UniformOutput', false);
                streams.doport = arrayfun(@(i) sprintf('doport%d',i), 0:5, 'UniformOutput', false);
            else % NI
                streams.ao = arrayfun(@(i) sprintf('ao%d',i), 0:3, 'UniformOutput', false);
                streams.ai = arrayfun(@(i) sprintf('ai%d',i), 0:31, 'UniformOutput', false);
                streams.doport = arrayfun(@(i) sprintf('doport%d',i), 0:2, 'UniformOutput', false);
            end
        end

        function all = getAllStreamsForCurrentDaq(obj)
            s = obj.getStreamsByCategory();
            all = [s.ao, s.ai, s.doport];
        end

        % ============================================================
        % Configuration settings
        % ============================================================
        function onAddConfig(obj)
            if obj.selectedIndex < 1, return; end
            answers = inputdlg( ...
                {'Setting name:', 'Default value:', 'Domain values (comma-separated):'}, ...
                'Add Configuration Setting', [1 50; 1 50; 1 50], ...
                {'ndfs', '{}', 'FW00, FW05, FW10, FW20, FW30, FW40'});
            if isempty(answers), return; end

            key = strtrim(answers{1});
            defVal = strtrim(answers{2});
            domainStr = strtrim(answers{3});
            if isempty(key), return; end

            % Parse domain
            domain = strsplit(domainStr, ',');
            domain = strtrim(domain);
            domain(cellfun(@isempty, domain)) = [];

            % Determine type
            if strcmp(defVal, '{}')
                propType = 'cellstr';
            else
                propType = 'char';
            end

            cfg = struct('name', key, 'defaultValue', defVal, ...
                'propType', propType, 'domain', {domain});

            d = obj.deviceList{obj.selectedIndex};
            d.configSettings{end+1} = cfg;
            obj.deviceList{obj.selectedIndex} = d;
            obj.populateConfigTable(d);
        end

        function onRemoveConfig(obj)
            if obj.selectedIndex < 1, return; end
            d = obj.deviceList{obj.selectedIndex};
            if isempty(d.configSettings), return; end

            sel = obj.configTable.Selection;
            if isempty(sel), return; end
            row = sel(1);
            d.configSettings(row) = [];
            obj.deviceList{obj.selectedIndex} = d;
            obj.populateConfigTable(d);
        end

        function populateConfigTable(obj, d)
            n = numel(d.configSettings);
            if n == 0
                obj.configTable.Data = cell(0, 4);
                return;
            end
            data = cell(n, 4);
            for i = 1:n
                c = d.configSettings{i};
                data{i,1} = c.name;
                data{i,2} = c.defaultValue;
                data{i,3} = c.propType;
                data{i,4} = strjoin(c.domain, ', ');
            end
            obj.configTable.Data = data;
        end

        % ============================================================
        % Code generation
        % ============================================================
        function code = generateCode(obj)
            if obj.selectedIndex > 0 && obj.selectedIndex <= numel(obj.deviceList)
                obj.savePanelToDevice(obj.selectedIndex);
            end

            className = strtrim(obj.classNameField.Value);
            nl = newline;

            lines = {};
            lines{end+1} = sprintf('classdef %s < symphonyui.core.descriptions.RigDescription', className);
            lines{end+1} = '';
            lines{end+1} = '    methods';
            lines{end+1} = sprintf('        function obj = %s()', className);
            lines{end+1} = '            import symphonyui.builtin.daqs.*;';
            lines{end+1} = '            import symphonyui.builtin.devices.*;';
            lines{end+1} = '            import symphonyui.core.*;';
            lines{end+1} = '';

            % DAQ construction
            daqType = obj.rigConfig.daqType;
            if contains(daqType, 'Ni') && ~isempty(strtrim(obj.daqArgsField.Value))
                devName = strtrim(obj.daqArgsField.Value);
                lines{end+1} = sprintf('            daq = %s(''%s'');', daqType, devName);
            else
                lines{end+1} = sprintf('            daq = %s();', daqType);
            end
            lines{end+1} = '            obj.daqController = daq;';

            % Devices
            usedVarNames = containers.Map();
            for i = 1:numel(obj.deviceList)
                lines{end+1} = ''; %#ok<AGROW>
                d = obj.deviceList{i};
                varName = obj.makeVarName(d.name, usedVarNames);

                switch d.type
                    case 'MultiClampDevice'
                        bindChain = '';
                        if ~isempty(d.outputStream)
                            bindChain = [bindChain, sprintf('.bindStream(daq.getStream(''%s''))', d.outputStream)];
                        end
                        if ~isempty(d.inputStream)
                            bindChain = [bindChain, sprintf('.bindStream(daq.getStream(''%s''))', d.inputStream)];
                        end
                        lines{end+1} = sprintf('            %s = MultiClampDevice(''%s'', %d)%s;', ...
                            varName, d.name, d.channelNumber, bindChain); %#ok<AGROW>

                    case 'UnitConvertingDevice'
                        unitsStr = obj.unitsCodeString(d.units);
                        bindChain = obj.buildBindChain(d);
                        lines{end+1} = sprintf('            %s = UnitConvertingDevice(''%s'', %s)%s;', ...
                            varName, d.name, unitsStr, bindChain); %#ok<AGROW>

                    case 'CalibratedDevice'
                        unitsStr = obj.unitsCodeString(d.units);
                        lines{end+1} = sprintf('            %% TODO: Load calibration ramp data for %s', d.name); %#ok<AGROW>
                        lines{end+1} = sprintf('            %% rampData = importdata(''path/to/gamma_ramp.txt'');'); %#ok<AGROW>
                        bindChain = obj.buildBindChain(d);
                        lines{end+1} = sprintf('            %s = CalibratedDevice(''%s'', %s, rampData(:,1), rampData(:,2))%s;', ...
                            varName, d.name, unitsStr, bindChain); %#ok<AGROW>

                    case 'SimulatedAmplifierDevice'
                        lines{end+1} = sprintf('            %s = SimulatedAmplifierDevice(''%s'', daq);', ...
                            varName, d.name); %#ok<AGROW>
                end

                % Digital bit position
                if ~isempty(d.digitalPort) && d.bitPosition >= 0
                    lines{end+1} = sprintf('            daq.getStream(''%s'').setBitPosition(%s, %d);', ...
                        d.digitalPort, varName, d.bitPosition); %#ok<AGROW>
                end

                % Configuration settings
                for j = 1:numel(d.configSettings)
                    c = d.configSettings{j};
                    domainStr = obj.formatDomainLiteral(c.domain);
                    if strcmp(c.propType, 'cellstr')
                        lines{end+1} = sprintf('            %s.addConfigurationSetting(''%s'', %s, ...', ...
                            varName, c.name, c.defaultValue); %#ok<AGROW>
                        lines{end+1} = sprintf('                ''type'', PropertyType(''cellstr'', ''row'', %s));', ...
                            domainStr); %#ok<AGROW>
                    else
                        lines{end+1} = sprintf('            %s.addConfigurationSetting(''%s'', ''%s'', ...', ...
                            varName, c.name, c.defaultValue); %#ok<AGROW>
                        lines{end+1} = sprintf('                ''type'', PropertyType(''char'', ''row'', %s));', ...
                            domainStr); %#ok<AGROW>
                    end
                end

                lines{end+1} = sprintf('            obj.addDevice(%s);', varName); %#ok<AGROW>
            end

            lines{end+1} = '        end';
            lines{end+1} = '';
            lines{end+1} = '    end';
            lines{end+1} = '';
            lines{end+1} = 'end';
            lines{end+1} = '';

            code = strjoin(lines, nl);
        end

        function onPreviewCode(obj)
            if isempty(obj.deviceList)
                uialert(obj.fig, 'Add at least one device first.', 'Preview');
                return;
            end
            code = obj.generateCode();

            prevFig = uifigure('Name', 'Generated Rig Code', ...
                'Position', [150 100 700 500]);
            g = uigridlayout(prevFig, [2 1]);
            g.RowHeight = {'1x', 36};
            g.Padding = [8 8 8 8];

            ta = uitextarea(g, 'Value', strsplit(code, newline), 'Editable', 'off', ...
                'FontName', 'Consolas');
            ta.Layout.Row = 1;

            btnRow = uigridlayout(g, [1 2]);
            btnRow.Layout.Row = 2;
            btnRow.ColumnWidth = {'1x', 120};
            btnRow.Padding = [0 0 0 0];
            uilabel(btnRow, 'Text', '');
            uibutton(btnRow, 'Text', 'Copy to Clipboard', ...
                'ButtonPushedFcn', @(~,~)clipboard('copy', code));
        end

        function onGenerateAndSave(obj)
            if isempty(obj.deviceList)
                uialert(obj.fig, 'Add at least one device first.', 'Generate');
                return;
            end

            className = strtrim(obj.classNameField.Value);
            if isempty(className) || ~isvarname(className)
                uialert(obj.fig, 'Enter a valid MATLAB class name.', 'Generate');
                return;
            end

            code = obj.generateCode();

            % Build output path from package + class name
            outDir = strtrim(obj.outputDirField.Value);
            pkgPath = strtrim(obj.packageField.Value);

            % Convert +my+rigs to file path segments
            if ~isempty(pkgPath)
                parts = strsplit(pkgPath, {'+', filesep, '/'});
                parts(cellfun(@isempty, parts)) = [];
                for i = 1:numel(parts)
                    outDir = fullfile(outDir, ['+' parts{i}]);
                end
            end

            if ~isfolder(outDir)
                mkdir(outDir);
            end

            filePath = fullfile(outDir, [className '.m']);
            fid = fopen(filePath, 'w');
            if fid < 0
                uialert(obj.fig, sprintf('Cannot write to:\n%s', filePath), 'File Error');
                return;
            end
            fprintf(fid, '%s', code);
            fclose(fid);

            uialert(obj.fig, sprintf('Rig saved to:\n%s', filePath), 'Success', 'Icon', 'success');
        end

        % ============================================================
        % Dialog plumbing
        % ============================================================
        function onBrowseDir(obj)
            folder = uigetdir(obj.outputDirField.Value, 'Select output directory');
            if folder ~= 0
                obj.outputDirField.Value = folder;
            end
        end

        function onCancel(obj)
            if isvalid(obj.fig)
                uiresume(obj.fig);
                delete(obj.fig);
            end
        end

        function onKeyPress(obj, event)
            if strcmp(event.Key, 'escape')
                obj.onCancel();
            end
        end

        function pos = centerOnParent(obj, w, h)
            if ~isempty(obj.parentFigure) && isvalid(obj.parentFigure)
                pp = obj.parentFigure.Position;
                pos = [pp(1) + (pp(3)-w)/2, pp(2) + (pp(4)-h)/2, w, h];
            else
                pos = [100 100 w h];
            end
        end

        function setRightPanelEnabled(obj, tf)
            if tf, state = 'on'; else, state = 'off'; end
            obj.deviceTypeDropdown.Enable = state;
            obj.deviceNameField.Enable = state;
            obj.channelSpinner.Enable = state;
            obj.deviceUnitsDropdown.Enable = state;
            obj.outputStreamDropdown.Enable = state;
            obj.inputStreamDropdown.Enable = state;
            obj.digitalPortDropdown.Enable = state;
            obj.bitPositionSpinner.Enable = state;
            obj.configTable.Enable = state;
        end

    end

    % ================================================================
    % Static helpers
    % ================================================================
    methods (Static, Access = private)

        function d = newDeviceStruct()
            d = struct( ...
                'name', '', ...
                'type', 'UnitConvertingDevice', ...
                'units', 'V', ...
                'outputStream', '', ...
                'inputStream', '', ...
                'digitalPort', '', ...
                'bitPosition', -1, ...
                'channelNumber', 1, ...
                'configSettings', {{}});
        end

        function s = streamOrEmpty(val)
            if strcmp(val, '(none)')
                s = '';
            else
                s = val;
            end
        end

        function setVisible(control, tf)
            if tf
                control.Visible = 'on';
            else
                control.Visible = 'off';
            end
        end

        function varName = makeVarName(deviceName, usedMap)
            % Convert device name to a valid MATLAB variable name
            v = lower(regexprep(deviceName, '[^a-zA-Z0-9]', ''));
            if isempty(v), v = 'dev'; end
            if isKey(usedMap, v)
                n = usedMap(v) + 1;
                usedMap(v) = n; %#ok<NASGU>
                v = sprintf('%s%d', v, n);
            else
                usedMap(v) = 1; %#ok<NASGU>
            end
            varName = v;
        end

        function s = unitsCodeString(units)
            switch units
                case 'UNITLESS'
                    s = 'Measurement.UNITLESS';
                case 'NORMALIZED'
                    s = 'Measurement.NORMALIZED';
                otherwise
                    s = sprintf('''%s''', units);
            end
        end

        function chain = buildBindChain(d)
            chain = '';
            if ~isempty(d.outputStream)
                chain = sprintf('.bindStream(daq.getStream(''%s''))', d.outputStream);
            end
            if ~isempty(d.inputStream)
                chain = [chain, sprintf('.bindStream(daq.getStream(''%s''))', d.inputStream)];
            end
            if ~isempty(d.digitalPort)
                chain = [chain, sprintf('.bindStream(daq.getStream(''%s''))', d.digitalPort)];
            end
        end

        function s = formatDomainLiteral(domain)
            if isempty(domain)
                s = '{}';
            else
                parts = cellfun(@(v) sprintf('''%s''', v), domain, 'UniformOutput', false);
                s = ['{' strjoin(parts, ', ') '}'];
            end
        end
    end

end
