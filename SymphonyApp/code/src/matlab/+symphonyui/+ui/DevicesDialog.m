classdef DevicesDialog < handle
    %DEVICESDIALOG  Configure → Devices (uifigure modal dialog).
    %   Two-pane layout: device listbox (left) and detail panel (right) showing
    %   device name, manufacturer, streams, background, and configuration settings.
    %   Uses the legacy configurationService (device info not yet in C# host API)
    %   but presents everything in UIFigure components. Replaces the old Java-based
    %   DevicesView + DevicesPresenter pair.

    properties (Access = private)
        fig matlab.ui.Figure
        parentFigure
        configService  % symphonyui.app.ConfigurationService (legacy)

        % Left pane
        deviceListBox matlab.ui.control.ListBox

        % Right pane — device details
        nameField matlab.ui.control.EditField
        manufacturerField matlab.ui.control.EditField
        inputStreamsField matlab.ui.control.EditField
        outputStreamsField matlab.ui.control.EditField
        backgroundField matlab.ui.control.EditField
        backgroundUnitsLabel matlab.ui.control.Label
        setBackgroundButton matlab.ui.control.Button

        % Configuration table
        configTable matlab.ui.control.Table
        addConfigButton matlab.ui.control.Button
        removeConfigButton matlab.ui.control.Button

        % Footer
        okButton matlab.ui.control.Button

        % State
        devices  % cell array of device objects
        currentDeviceSet  % DeviceSet for selected devices
    end

    methods (Static)
        function showBlocking(parentFigure, configService)
            %SHOWBLOCKING  Open modal Devices dialog and block until Ok.
            dlg = symphonyui.ui.DevicesDialog(parentFigure, configService);
            dlg.fig.Visible = 'on';
            uiwait(dlg.fig);
        end
    end

    methods (Access = private)
        function obj = DevicesDialog(parentFigure, configService)
            obj.parentFigure = parentFigure;
            obj.configService = configService;
            obj.devices = {};
            obj.buildUi();
            obj.populate();
        end

        function buildUi(obj)
            w = 600;
            h = 420;
            pos = obj.centerOnParent(w, h);

            obj.fig = uifigure( ...
                'Name', 'Devices', ...
                'Position', pos, ...
                'WindowStyle', 'modal', ...
                'Color', [0.94 0.94 0.94], ...
                'CloseRequestFcn', @(~,~)obj.onOk(), ...
                'KeyPressFcn', @(~,e)obj.onKeyPress(e));

            main = uigridlayout(obj.fig, [2 1]);
            main.RowHeight = {'1x', 40};
            main.Padding = [10 10 10 10];
            main.RowSpacing = 8;

            % Top: two-pane layout
            panes = uigridlayout(main, [1 2]);
            panes.Layout.Row = 1;
            panes.ColumnWidth = {160, '1x'};
            panes.Padding = [0 0 0 0];
            panes.ColumnSpacing = 8;

            % Left pane: device list
            obj.deviceListBox = uilistbox(panes, ...
                'Items', {}, ...
                'ValueChangedFcn', @(~,~)obj.onDeviceSelected());
            obj.deviceListBox.Layout.Column = 1;

            % Right pane: details
            detail = uigridlayout(panes, [8 3]);
            detail.Layout.Column = 2;
            detail.RowHeight = {24, 24, 24, 24, 24, 10, '1x', 28};
            detail.ColumnWidth = {90, '1x', 70};
            detail.Padding = [0 0 0 0];
            detail.RowSpacing = 4;
            detail.ColumnSpacing = 6;

            % Name (read-only)
            lbl1 = uilabel(detail, 'Text', 'Name:', 'HorizontalAlignment', 'right');
            lbl1.Layout.Row = 1; lbl1.Layout.Column = 1;
            obj.nameField = uieditfield(detail, 'text', 'Editable', 'off');
            obj.nameField.Layout.Row = 1; obj.nameField.Layout.Column = [2 3];

            % Manufacturer (read-only)
            lbl2 = uilabel(detail, 'Text', 'Manufacturer:', 'HorizontalAlignment', 'right');
            lbl2.Layout.Row = 2; lbl2.Layout.Column = 1;
            obj.manufacturerField = uieditfield(detail, 'text', 'Editable', 'off');
            obj.manufacturerField.Layout.Row = 2; obj.manufacturerField.Layout.Column = [2 3];

            % Input streams (read-only)
            lbl3 = uilabel(detail, 'Text', 'Input:', 'HorizontalAlignment', 'right');
            lbl3.Layout.Row = 3; lbl3.Layout.Column = 1;
            obj.inputStreamsField = uieditfield(detail, 'text', 'Editable', 'off');
            obj.inputStreamsField.Layout.Row = 3; obj.inputStreamsField.Layout.Column = [2 3];

            % Output streams (read-only)
            lbl4 = uilabel(detail, 'Text', 'Output:', 'HorizontalAlignment', 'right');
            lbl4.Layout.Row = 4; lbl4.Layout.Column = 1;
            obj.outputStreamsField = uieditfield(detail, 'text', 'Editable', 'off');
            obj.outputStreamsField.Layout.Row = 4; obj.outputStreamsField.Layout.Column = [2 3];

            % Background (editable)
            lbl5 = uilabel(detail, 'Text', 'Background:', 'HorizontalAlignment', 'right');
            lbl5.Layout.Row = 5; lbl5.Layout.Column = 1;
            obj.backgroundField = uieditfield(detail, 'text');
            obj.backgroundField.Layout.Row = 5; obj.backgroundField.Layout.Column = 2;
            bgBtnGrid = uigridlayout(detail, [1 2]);
            bgBtnGrid.Layout.Row = 5;
            bgBtnGrid.Layout.Column = 3;
            bgBtnGrid.ColumnWidth = {'1x', 28};
            bgBtnGrid.Padding = [0 0 0 0];
            obj.backgroundUnitsLabel = uilabel(bgBtnGrid, 'Text', '');
            obj.setBackgroundButton = uibutton(bgBtnGrid, 'Text', 'Set', ...
                'ButtonPushedFcn', @(~,~)obj.onSetBackground());

            % Separator / spacer row 6

            % Configuration table
            configLabel = uilabel(detail, 'Text', 'Configuration:', 'FontWeight', 'bold');
            configLabel.Layout.Row = 6;
            configLabel.Layout.Column = [1 3];

            obj.configTable = uitable(detail, ...
                'ColumnName', {'Setting', 'Value'}, ...
                'ColumnEditable', [false true], ...
                'ColumnWidth', {'1x', '1x'}, ...
                'CellEditCallback', @(~,e)obj.onConfigEdited(e));
            obj.configTable.Layout.Row = 7;
            obj.configTable.Layout.Column = [1 3];

            % Config buttons
            cfgBtnGrid = uigridlayout(detail, [1 3]);
            cfgBtnGrid.Layout.Row = 8;
            cfgBtnGrid.Layout.Column = [1 3];
            cfgBtnGrid.ColumnWidth = {'1x', 70, 70};
            cfgBtnGrid.Padding = [0 0 0 0];

            uilabel(cfgBtnGrid, 'Text', '');  % spacer
            obj.addConfigButton = uibutton(cfgBtnGrid, 'Text', 'Add...', ...
                'ButtonPushedFcn', @(~,~)obj.onAddConfig());
            obj.removeConfigButton = uibutton(cfgBtnGrid, 'Text', 'Remove', ...
                'ButtonPushedFcn', @(~,~)obj.onRemoveConfig());

            % Footer: Ok button
            btnGrid = uigridlayout(main, [1 2]);
            btnGrid.Layout.Row = 2;
            btnGrid.ColumnWidth = {'1x', 80};
            btnGrid.Padding = [0 0 0 0];

            uilabel(btnGrid, 'Text', '');  % spacer
            obj.okButton = uibutton(btnGrid, 'Text', 'Ok', ...
                'ButtonPushedFcn', @(~,~)obj.onOk());

            symphonyui.ui.DialogUtil.setKeyPressFcnRecursive(obj.fig, @(~,e)obj.onKeyPress(e));
        end

        function populate(obj)
            try
                obj.devices = obj.configService.getDevices();
                if isempty(obj.devices)
                    obj.deviceListBox.Items = {'(no devices)'};
                    obj.enableDetailControls(false);
                    return;
                end
                names = cellfun(@(d)d.name, obj.devices, 'UniformOutput', false);
                obj.deviceListBox.Items = names;
                obj.deviceListBox.Value = names{1};
                obj.onDeviceSelected();
            catch ex
                obj.deviceListBox.Items = {'(error loading devices)'};
                obj.enableDetailControls(false);
                uialert(obj.fig, ex.message, 'Devices');
            end
        end

        function onDeviceSelected(obj)
            if isempty(obj.devices)
                return;
            end
            idx = find(strcmp(obj.deviceListBox.Items, obj.deviceListBox.Value), 1);
            if isempty(idx)
                return;
            end

            try
                device = obj.devices{idx};
                deviceSet = symphonyui.core.collections.DeviceSet({device});
                obj.currentDeviceSet = deviceSet;

                obj.nameField.Value = deviceSet.name;
                obj.manufacturerField.Value = deviceSet.manufacturer;

                % Streams
                inputStreams = deviceSet.getInputStreams();
                obj.inputStreamsField.Value = strjoin(cellfun(@(s)s.name, inputStreams, 'UniformOutput', false), ', ');
                outputStreams = deviceSet.getOutputStreams();
                obj.outputStreamsField.Value = strjoin(cellfun(@(s)s.name, outputStreams, 'UniformOutput', false), ', ');

                % Background
                bg = deviceSet.background;
                if isempty(bg)
                    obj.backgroundField.Value = '';
                    obj.backgroundUnitsLabel.Text = '';
                else
                    obj.backgroundField.Value = num2str(bg.quantity);
                    obj.backgroundUnitsLabel.Text = deviceSet.getBackgroundDisplayUnits();
                end
                hasBg = ~isempty(deviceSet.getBackgroundDisplayUnits()) && deviceSet.allHaveBoundOutputStreams();
                obj.backgroundField.Enable = hasBg;
                obj.setBackgroundButton.Enable = hasBg;

                % Configuration
                obj.populateConfig(deviceSet);
            catch ex
                obj.nameField.Value = '';
                obj.manufacturerField.Value = '';
                obj.inputStreamsField.Value = '';
                obj.outputStreamsField.Value = '';
                obj.backgroundField.Value = '';
                obj.configTable.Data = {};
                uialert(obj.fig, ex.message, 'Devices');
            end
        end

        function populateConfig(obj, deviceSet)
            try
                descriptors = deviceSet.getConfigurationSettingDescriptors();
                n = numel(descriptors);
                fprintf('DevicesDialog.populateConfig: %d descriptors\n', n);
                if n == 0
                    obj.configTable.Data = cell(0, 2);
                    return;
                end
                data = cell(n, 2);
                for i = 1:n
                    d = descriptors(i);
                    data{i, 1} = d.name;
                    v = d.value;
                    if ischar(v) || isstring(v)
                        data{i, 2} = char(v);
                    elseif islogical(v)
                        if v, data{i, 2} = 'true'; else, data{i, 2} = 'false'; end
                    elseif isnumeric(v) && isscalar(v)
                        data{i, 2} = num2str(v);
                    elseif isnumeric(v)
                        data{i, 2} = mat2str(v);
                    elseif iscell(v)
                        % Cell array of strings (e.g. cellstr)
                        try
                            data{i, 2} = strjoin(cellfun(@char, v, 'UniformOutput', false), '; ');
                        catch
                            data{i, 2} = '<cell>';
                        end
                    elseif isa(v, 'symphonyui.core.Measurement')
                        data{i, 2} = sprintf('%g %s', v.quantity, v.displayUnits);
                    else
                        try
                            data{i, 2} = char(string(v));
                        catch
                            data{i, 2} = class(v);
                        end
                    end
                end
                obj.configTable.Data = data;
            catch ex
                fprintf(2, 'DevicesDialog.populateConfig error: %s\n', ex.message);
                for k = 1:numel(ex.stack)
                    fprintf(2, '  in %s (line %d)\n', ex.stack(k).name, ex.stack(k).line);
                end
                obj.configTable.Data = cell(0, 2);
            end
        end

        function onSetBackground(obj)
            if isempty(obj.currentDeviceSet)
                return;
            end
            try
                val = str2double(obj.backgroundField.Value);
                units = obj.backgroundUnitsLabel.Text;
                obj.currentDeviceSet.background = symphonyui.core.Measurement(val, units);
                obj.currentDeviceSet.applyBackground();
            catch ex
                uialert(obj.fig, ex.message, 'Set Background Error');
            end
        end

        function onConfigEdited(obj, event)
            if isempty(obj.currentDeviceSet)
                return;
            end
            row = event.Indices(1);
            data = obj.configTable.Data;
            key = data{row, 1};
            rawVal = data{row, 2};
            try
                val = str2double(rawVal);
                if isnan(val)
                    val = rawVal;  % keep as string
                end
                obj.currentDeviceSet.setConfigurationSetting(key, val);
                obj.populateConfig(obj.currentDeviceSet);
            catch ex
                uialert(obj.fig, ex.message, 'Configuration Error');
                obj.populateConfig(obj.currentDeviceSet);
            end
        end

        function onAddConfig(obj)
            if isempty(obj.currentDeviceSet)
                return;
            end
            answers = inputdlg({'Key:', 'Value:'}, 'Add Configuration Setting', [1 40; 1 40]);
            if isempty(answers)
                return;
            end
            key = strtrim(answers{1});
            rawVal = strtrim(answers{2});
            if isempty(key)
                return;
            end
            try
                val = str2double(rawVal);
                if isnan(val)
                    val = rawVal;
                end
                obj.currentDeviceSet.addConfigurationSetting(key, val, 'isRemovable', true);
                obj.populateConfig(obj.currentDeviceSet);
            catch ex
                uialert(obj.fig, ex.message, 'Add Configuration Error');
            end
        end

        function onRemoveConfig(obj)
            if isempty(obj.currentDeviceSet)
                return;
            end
            data = obj.configTable.Data;
            if isempty(data)
                return;
            end
            % Use selection if available, otherwise last row
            sel = obj.configTable.Selection;
            if isempty(sel)
                uialert(obj.fig, 'Select a configuration setting first.', 'Remove');
                return;
            end
            row = sel(1);
            key = data{row, 1};
            try
                obj.currentDeviceSet.removeConfigurationSetting(key);
                obj.populateConfig(obj.currentDeviceSet);
            catch ex
                uialert(obj.fig, ex.message, 'Remove Configuration Error');
            end
        end

        function onOk(obj)
            if isvalid(obj.fig)
                uiresume(obj.fig);
                delete(obj.fig);
            end
        end

        function onKeyPress(obj, event)
            switch event.Key
                case {'return', 'escape'}
                    obj.onOk();
            end
        end

        function enableDetailControls(obj, tf)
            state = tf;
            obj.backgroundField.Enable = state;
            obj.setBackgroundButton.Enable = state;
            obj.addConfigButton.Enable = state;
            obj.removeConfigButton.Enable = state;
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
end
