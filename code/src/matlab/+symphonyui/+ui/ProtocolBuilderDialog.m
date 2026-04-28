classdef ProtocolBuilderDialog < handle
    %PROTOCOLBUILDERDIALOG  Visual protocol scaffold builder.
    %   Lets users define properties, choose stimulus templates, pick online
    %   analysis figures, and generates the complete .m class file.
    %
    %   Usage:
    %       symphonyui.ui.ProtocolBuilderDialog.showBlocking(parentFigure)

    properties (Access = private)
        fig matlab.ui.Figure
        parentFigure

        % --- Data model ---
        protoConfig     % struct: className, packagePath, outputDir, baseClass
        propList        % cell array of property structs
        stimConfig      % struct: generatorType, deviceProp, extra fields
        figureChecks    % struct of logicals for each built-in figure
        epochControl    % struct: useNumberOfAverages, interpulseInterval

        % --- Top bar ---
        classNameField matlab.ui.control.EditField
        packageField matlab.ui.control.EditField
        outputDirField matlab.ui.control.EditField
        baseClassDropdown matlab.ui.control.DropDown

        % --- Left panel: property list ---
        propListBox matlab.ui.control.ListBox
        selectedPropIndex double = 0

        % --- Right panel: property detail ---
        propNameField matlab.ui.control.EditField
        propTypeDropdown matlab.ui.control.DropDown
        propDefaultField matlab.ui.control.EditField
        propDomainField matlab.ui.control.EditField
        propDescriptionField matlab.ui.control.EditField
        propIsDeviceCheck matlab.ui.control.CheckBox
        propCategoryField matlab.ui.control.EditField
        propPanel  % grid for enable/disable

        % --- Stimulus tab ---
        stimDevicePropDropdown matlab.ui.control.DropDown
        stimGeneratorDropdown matlab.ui.control.DropDown
        stimInfoArea matlab.ui.control.TextArea

        % --- Figures tab ---
        chkResponse matlab.ui.control.CheckBox
        chkMeanResponse matlab.ui.control.CheckBox
        chkResponseStats matlab.ui.control.CheckBox
        chkCustom matlab.ui.control.CheckBox
        meanGroupByField matlab.ui.control.EditField
        statsBaselineField matlab.ui.control.EditField
        statsMeasureField matlab.ui.control.EditField

        % --- Epoch tab ---
        chkUseNumAverages matlab.ui.control.CheckBox
        numAveragesDefault matlab.ui.control.Spinner
        chkInterpulse matlab.ui.control.CheckBox
        interpulseDefault matlab.ui.control.Spinner

        % --- Tab group ---
        tabGroup matlab.ui.container.TabGroup
    end

    % ================================================================
    % Static entry point
    % ================================================================
    methods (Static)
        function showBlocking(parentFigure)
            if nargin < 1, parentFigure = []; end
            dlg = symphonyui.ui.ProtocolBuilderDialog(parentFigure);
            dlg.fig.Visible = 'on';
            uiwait(dlg.fig);
        end
    end

    % ================================================================
    % Construction & lifecycle
    % ================================================================
    methods (Access = private)

        function obj = ProtocolBuilderDialog(parentFigure)
            obj.parentFigure = parentFigure;
            obj.propList = {};
            obj.initDefaults();
            obj.buildUi();
        end

        function initDefaults(obj)
            obj.protoConfig = struct( ...
                'className', 'MyProtocol', ...
                'packagePath', '+my+protocols', ...
                'outputDir', pwd, ...
                'baseClass', 'symphonyui.core.Protocol');

            obj.stimConfig = struct( ...
                'generatorType', 'PulseGenerator', ...
                'deviceProp', 'amp');

            obj.figureChecks = struct( ...
                'response', true, ...
                'meanResponse', true, ...
                'responseStats', false, ...
                'custom', false);

            obj.epochControl = struct( ...
                'useNumberOfAverages', true, ...
                'defaultNumAverages', 5, ...
                'useInterpulse', true, ...
                'defaultInterpulse', 0);

            % Seed with common default properties
            obj.propList = { ...
                obj.makeProp('amp',    'device', '',    '', 'Output amplifier', ''), ...
                obj.makeProp('preTime',  'double', '50',  '', 'Pulse leading duration (ms)', ''), ...
                obj.makeProp('stimTime', 'double', '500', '', 'Pulse duration (ms)', ''), ...
                obj.makeProp('tailTime', 'double', '50',  '', 'Pulse trailing duration (ms)', '') ...
            };
        end

        % ============================================================
        % UI Construction
        % ============================================================
        function buildUi(obj)
            w = 920; h = 680;
            pos = obj.centerOnParent(w, h);

            obj.fig = uifigure( ...
                'Name', 'Protocol Builder', ...
                'Position', pos, ...
                'Resize', 'on', ...
                'Color', [0.94 0.94 0.94], ...
                'Visible', 'off', ...
                'CloseRequestFcn', @(~,~)obj.onCancel(), ...
                'KeyPressFcn', @(~,e)obj.onKeyPress(e));

            main = uigridlayout(obj.fig, [3 1]);
            main.RowHeight = {80, '1x', 40};
            main.Padding = [10 10 10 10];
            main.RowSpacing = 8;

            obj.buildTopBar(main);
            obj.buildBody(main);
            obj.buildFooter(main);

            symphonyui.ui.DialogUtil.setKeyPressFcnRecursive(obj.fig, @(~,e)obj.onKeyPress(e));
            symphonyui.ui.ViewSettings.installAutoSave(obj.fig, 'ProtocolBuilder');
        end

        % ----- Top bar -----
        function buildTopBar(obj, parent)
            top = uigridlayout(parent, [3 6]);
            top.Layout.Row = 1;
            top.RowHeight = {24, 24, 24};
            top.ColumnWidth = {80, '1x', 80, '1x', 80, '1x'};
            top.Padding = [0 0 0 0];
            top.RowSpacing = 4;
            top.ColumnSpacing = 6;

            % Row 1
            lbl = uilabel(top, 'Text', 'Class Name:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 1; lbl.Layout.Column = 1;
            obj.classNameField = uieditfield(top, 'text', ...
                'Value', obj.protoConfig.className);
            obj.classNameField.Layout.Row = 1; obj.classNameField.Layout.Column = 2;

            lbl = uilabel(top, 'Text', 'Package:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 1; lbl.Layout.Column = 3;
            obj.packageField = uieditfield(top, 'text', ...
                'Value', obj.protoConfig.packagePath, ...
                'Tooltip', 'MATLAB package path, e.g. +my+protocols');
            obj.packageField.Layout.Row = 1; obj.packageField.Layout.Column = 4;

            lbl = uilabel(top, 'Text', 'Output Dir:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 1; lbl.Layout.Column = 5;
            obj.outputDirField = uieditfield(top, 'text', ...
                'Value', obj.protoConfig.outputDir);
            obj.outputDirField.Layout.Row = 1; obj.outputDirField.Layout.Column = 6;

            % Row 2
            lbl = uilabel(top, 'Text', 'Base Class:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 2; lbl.Layout.Column = 1;
            obj.baseClassDropdown = uidropdown(top, ...
                'Items', {'symphonyui.core.Protocol', ...
                          'common.protocols.CommonProtocol', ...
                          'common.protocols.CommonStageProtocol', ...
                          'manookinlab.protocols.ManookinLabStageProtocol'}, ...
                'Value', 'symphonyui.core.Protocol', ...
                'Editable', 'on', ...
                'Tooltip', 'Enter a custom base class or pick from the list');
            obj.baseClassDropdown.Layout.Row = 2; obj.baseClassDropdown.Layout.Column = [2 4];

            browseBtn = uibutton(top, 'Text', 'Browse...', ...
                'ButtonPushedFcn', @(~,~)obj.onBrowseDir());
            browseBtn.Layout.Row = 2; browseBtn.Layout.Column = 6;
        end

        % ----- Body: left panel (props) + right tabs -----
        function buildBody(obj, parent)
            body = uigridlayout(parent, [1 2]);
            body.Layout.Row = 2;
            body.ColumnWidth = {240, '1x'};
            body.Padding = [0 0 0 0];
            body.ColumnSpacing = 8;

            obj.buildLeftPanel(body);
            obj.buildRightTabs(body);
        end

        % ----- Left panel: property list -----
        function buildLeftPanel(obj, parent)
            left = uigridlayout(parent, [3 1]);
            left.Layout.Column = 1;
            left.RowHeight = {20, '1x', 28};
            left.Padding = [0 0 0 0];
            left.RowSpacing = 4;

            lbl = uilabel(left, 'Text', 'Protocol Properties:', 'FontWeight', 'bold');
            lbl.Layout.Row = 1;

            obj.propListBox = uilistbox(left, ...
                'Items', {}, ...
                'ValueChangedFcn', @(~,~)obj.onPropSelected());
            obj.propListBox.Layout.Row = 2;

            btnRow = uigridlayout(left, [1 4]);
            btnRow.Layout.Row = 3;
            btnRow.ColumnWidth = {'1x', '1x', '1x', '1x'};
            btnRow.Padding = [0 0 0 0];
            btnRow.ColumnSpacing = 4;
            uibutton(btnRow, 'Text', '+ Add',   'ButtonPushedFcn', @(~,~)obj.onAddProp());
            uibutton(btnRow, 'Text', '- Remove', 'ButtonPushedFcn', @(~,~)obj.onRemoveProp());
            uibutton(btnRow, 'Text', char(9650), 'ButtonPushedFcn', @(~,~)obj.onMovePropUp(),   'Tooltip', 'Move Up');
            uibutton(btnRow, 'Text', char(9660), 'ButtonPushedFcn', @(~,~)obj.onMovePropDown(), 'Tooltip', 'Move Down');
        end

        % ----- Right tabs: Property Detail | Stimulus | Figures | Epochs -----
        function buildRightTabs(obj, parent)
            obj.tabGroup = uitabgroup(parent);
            obj.tabGroup.Layout.Column = 2;

            obj.buildPropertyTab(uitab(obj.tabGroup, 'Title', 'Property Detail'));
            obj.buildStimulusTab(uitab(obj.tabGroup, 'Title', 'Stimulus'));
            obj.buildFiguresTab(uitab(obj.tabGroup, 'Title', 'Figures'));
            obj.buildEpochTab(uitab(obj.tabGroup, 'Title', 'Epoch Control'));
        end

        % --- Property Detail tab ---
        function buildPropertyTab(obj, tab)
            obj.propPanel = uigridlayout(tab, [7 2]);
            obj.propPanel.RowHeight = {24, 24, 24, 24, 24, 24, 24};
            obj.propPanel.ColumnWidth = {100, '1x'};
            obj.propPanel.Padding = [8 8 8 8];
            obj.propPanel.RowSpacing = 6;
            obj.propPanel.ColumnSpacing = 6;
            rp = obj.propPanel;

            % Row 1: Name
            lbl = uilabel(rp, 'Text', 'Name:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 1; lbl.Layout.Column = 1;
            obj.propNameField = uieditfield(rp, 'text', 'Value', '', ...
                'ValueChangedFcn', @(~,~)obj.onPropFieldChanged());
            obj.propNameField.Layout.Row = 1; obj.propNameField.Layout.Column = 2;

            % Row 2: MATLAB type
            lbl = uilabel(rp, 'Text', 'Type:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 2; lbl.Layout.Column = 1;
            obj.propTypeDropdown = uidropdown(rp, ...
                'Items', {'double', 'int32', 'uint16', 'logical', 'char', 'cellstr', 'device'}, ...
                'Value', 'double', ...
                'ValueChangedFcn', @(~,~)obj.onPropFieldChanged());
            obj.propTypeDropdown.Layout.Row = 2; obj.propTypeDropdown.Layout.Column = 2;

            % Row 3: Default value
            lbl = uilabel(rp, 'Text', 'Default:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 3; lbl.Layout.Column = 1;
            obj.propDefaultField = uieditfield(rp, 'text', 'Value', '', ...
                'Tooltip', 'MATLAB expression for default value', ...
                'ValueChangedFcn', @(~,~)obj.onPropFieldChanged());
            obj.propDefaultField.Layout.Row = 3; obj.propDefaultField.Layout.Column = 2;

            % Row 4: Domain (optional)
            lbl = uilabel(rp, 'Text', 'Domain:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 4; lbl.Layout.Column = 1;
            obj.propDomainField = uieditfield(rp, 'text', 'Value', '', ...
                'Tooltip', 'Range [lo hi] or enum {''a'',''b''} or leave empty', ...
                'ValueChangedFcn', @(~,~)obj.onPropFieldChanged());
            obj.propDomainField.Layout.Row = 4; obj.propDomainField.Layout.Column = 2;

            % Row 5: Description (becomes comment)
            lbl = uilabel(rp, 'Text', 'Description:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 5; lbl.Layout.Column = 1;
            obj.propDescriptionField = uieditfield(rp, 'text', 'Value', '', ...
                'Tooltip', 'Becomes the property comment (shows in UI)', ...
                'ValueChangedFcn', @(~,~)obj.onPropFieldChanged());
            obj.propDescriptionField.Layout.Row = 5; obj.propDescriptionField.Layout.Column = 2;

            % Row 6: Category
            lbl = uilabel(rp, 'Text', 'Category:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 6; lbl.Layout.Column = 1;
            obj.propCategoryField = uieditfield(rp, 'text', 'Value', '', ...
                'Tooltip', 'Optional grouping category', ...
                'ValueChangedFcn', @(~,~)obj.onPropFieldChanged());
            obj.propCategoryField.Layout.Row = 6; obj.propCategoryField.Layout.Column = 2;

            % Row 7: Is Device property
            lbl = uilabel(rp, 'Text', '', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 7; lbl.Layout.Column = 1;
            obj.propIsDeviceCheck = uicheckbox(rp, ...
                'Text', 'Device selector (auto-creates hidden Type property)', ...
                'Value', false, ...
                'ValueChangedFcn', @(~,~)obj.onPropDeviceToggle());
            obj.propIsDeviceCheck.Layout.Row = 7; obj.propIsDeviceCheck.Layout.Column = 2;

            obj.setPropPanelEnabled(false);
        end

        % --- Stimulus tab ---
        function buildStimulusTab(obj, tab)
            g = uigridlayout(tab, [5 2]);
            g.RowHeight = {24, 24, 20, '1x', 24};
            g.ColumnWidth = {110, '1x'};
            g.Padding = [8 8 8 8];
            g.RowSpacing = 6;
            g.ColumnSpacing = 6;

            lbl = uilabel(g, 'Text', 'Device Prop:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 1; lbl.Layout.Column = 1;
            obj.stimDevicePropDropdown = uidropdown(g, ...
                'Items', {'amp'}, 'Value', 'amp', 'Editable', 'on', ...
                'Tooltip', 'Property name that selects the stimulus device');
            obj.stimDevicePropDropdown.Layout.Row = 1; obj.stimDevicePropDropdown.Layout.Column = 2;

            lbl = uilabel(g, 'Text', 'Generator:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 2; lbl.Layout.Column = 1;
            obj.stimGeneratorDropdown = uidropdown(g, ...
                'Items', {'PulseGenerator', 'PulseTrainGenerator', ...
                          'DirectCurrentGenerator', 'SineGenerator', ...
                          'SquareGenerator', 'RampGenerator', '(none)'}, ...
                'Value', 'PulseGenerator', ...
                'ValueChangedFcn', @(~,~)obj.onGeneratorChanged());
            obj.stimGeneratorDropdown.Layout.Row = 2; obj.stimGeneratorDropdown.Layout.Column = 2;

            lbl = uilabel(g, 'Text', 'Generator parameters:', 'FontWeight', 'bold');
            lbl.Layout.Row = 3; lbl.Layout.Column = [1 2];

            obj.stimInfoArea = uitextarea(g, 'Editable', 'off', ...
                'FontName', 'Consolas');
            obj.stimInfoArea.Layout.Row = 4; obj.stimInfoArea.Layout.Column = [1 2];

            helpLabel = uilabel(g, 'Text', ...
                'Properties above (preTime, stimTime, etc.) map to generator fields automatically.', ...
                'FontAngle', 'italic', 'FontColor', [0.4 0.4 0.4]);
            helpLabel.Layout.Row = 5; helpLabel.Layout.Column = [1 2];

            obj.refreshGeneratorInfo();
        end

        % --- Figures tab ---
        function buildFiguresTab(obj, tab)
            g = uigridlayout(tab, [7 2]);
            g.RowHeight = {24, 24, 24, 24, 10, 24, 24};
            g.ColumnWidth = {200, '1x'};
            g.Padding = [8 8 8 8];
            g.RowSpacing = 4;
            g.ColumnSpacing = 6;

            obj.chkResponse = uicheckbox(g, 'Text', 'ResponseFigure', ...
                'Value', true);
            obj.chkResponse.Layout.Row = 1; obj.chkResponse.Layout.Column = [1 2];

            obj.chkMeanResponse = uicheckbox(g, 'Text', 'MeanResponseFigure', ...
                'Value', true);
            obj.chkMeanResponse.Layout.Row = 2; obj.chkMeanResponse.Layout.Column = 1;

            gbyRow = uigridlayout(g, [1 2]);
            gbyRow.Layout.Row = 2; gbyRow.Layout.Column = 2;
            gbyRow.ColumnWidth = {70, '1x'};
            gbyRow.Padding = [0 0 0 0];
            uilabel(gbyRow, 'Text', 'groupBy:');
            obj.meanGroupByField = uieditfield(gbyRow, 'text', 'Value', '', ...
                'Tooltip', 'Epoch parameter name for grouping (optional)');

            obj.chkResponseStats = uicheckbox(g, 'Text', 'ResponseStatisticsFigure', ...
                'Value', false);
            obj.chkResponseStats.Layout.Row = 3; obj.chkResponseStats.Layout.Column = 1;

            statsGrid = uigridlayout(g, [2 2]);
            statsGrid.Layout.Row = [3 4]; statsGrid.Layout.Column = 2;
            statsGrid.RowHeight = {24, 24};
            statsGrid.ColumnWidth = {70, '1x'};
            statsGrid.Padding = [0 0 0 0];
            statsGrid.RowSpacing = 4;
            uilabel(statsGrid, 'Text', 'baseline:');
            obj.statsBaselineField = uieditfield(statsGrid, 'text', ...
                'Value', '[0 preTime]', ...
                'Tooltip', 'Baseline region [start end] in ms');
            uilabel(statsGrid, 'Text', 'measure:');
            obj.statsMeasureField = uieditfield(statsGrid, 'text', ...
                'Value', '[preTime preTime+stimTime]', ...
                'Tooltip', 'Measurement region [start end] in ms');

            % spacer
            lbl = uilabel(g, 'Text', '');
            lbl.Layout.Row = 5; lbl.Layout.Column = [1 2];

            obj.chkCustom = uicheckbox(g, 'Text', 'Include CustomFigure stub', ...
                'Value', false);
            obj.chkCustom.Layout.Row = 6; obj.chkCustom.Layout.Column = [1 2];

            helpLabel = uilabel(g, 'Text', ...
                'Selected figures are shown in prepareRun(). Device is taken from the stimulus device property.', ...
                'FontAngle', 'italic', 'FontColor', [0.4 0.4 0.4]);
            helpLabel.Layout.Row = 7; helpLabel.Layout.Column = [1 2];
        end

        % --- Epoch Control tab ---
        function buildEpochTab(obj, tab)
            g = uigridlayout(tab, [5 2]);
            g.RowHeight = {24, 24, 20, 24, 24};
            g.ColumnWidth = {250, '1x'};
            g.Padding = [8 8 8 8];
            g.RowSpacing = 6;
            g.ColumnSpacing = 6;

            obj.chkUseNumAverages = uicheckbox(g, 'Text', ...
                'Use numberOfAverages loop control', 'Value', true);
            obj.chkUseNumAverages.Layout.Row = 1; obj.chkUseNumAverages.Layout.Column = [1 2];

            lbl = uilabel(g, 'Text', 'Default numberOfAverages:', ...
                'HorizontalAlignment', 'right');
            lbl.Layout.Row = 2; lbl.Layout.Column = 1;
            obj.numAveragesDefault = uispinner(g, 'Value', 5, ...
                'Limits', [1 99999], 'Step', 1);
            obj.numAveragesDefault.Layout.Row = 2; obj.numAveragesDefault.Layout.Column = 2;

            lbl = uilabel(g, 'Text', ''); % spacer
            lbl.Layout.Row = 3; lbl.Layout.Column = [1 2];

            obj.chkInterpulse = uicheckbox(g, 'Text', ...
                'Include interpulseInterval property', 'Value', true);
            obj.chkInterpulse.Layout.Row = 4; obj.chkInterpulse.Layout.Column = [1 2];

            lbl = uilabel(g, 'Text', 'Default interval (s):', ...
                'HorizontalAlignment', 'right');
            lbl.Layout.Row = 5; lbl.Layout.Column = 1;
            obj.interpulseDefault = uispinner(g, 'Value', 0, ...
                'Limits', [0 3600], 'Step', 0.5);
            obj.interpulseDefault.Layout.Row = 5; obj.interpulseDefault.Layout.Column = 2;
        end

        % ----- Footer -----
        function buildFooter(obj, parent)
            footer = uigridlayout(parent, [1 4]);
            footer.Layout.Row = 3;
            footer.ColumnWidth = {'1x', 110, 110, 80};
            footer.Padding = [0 0 0 0];
            footer.ColumnSpacing = 8;

            uilabel(footer, 'Text', '');  % spacer
            uibutton(footer, 'Text', 'Preview Code...', ...
                'ButtonPushedFcn', @(~,~)obj.onPreviewCode());
            uibutton(footer, 'Text', 'Generate && Save', ...
                'ButtonPushedFcn', @(~,~)obj.onGenerateAndSave());
            uibutton(footer, 'Text', 'Cancel', ...
                'ButtonPushedFcn', @(~,~)obj.onCancel());
        end

        % ============================================================
        % Property list management
        % ============================================================
        function onAddProp(obj)
            n = numel(obj.propList) + 1;
            p = obj.makeProp(sprintf('param%d', n), 'double', '0', '', '', '');
            obj.propList{end+1} = p;
            obj.refreshPropListBox();
            obj.selectedPropIndex = numel(obj.propList);
            obj.propListBox.Value = obj.selectedPropIndex;
            obj.loadPropToPanel(obj.selectedPropIndex);
            obj.setPropPanelEnabled(true);
            obj.tabGroup.SelectedTab = obj.tabGroup.Children(1); % switch to property tab
        end

        function onRemoveProp(obj)
            if obj.selectedPropIndex < 1 || obj.selectedPropIndex > numel(obj.propList)
                return;
            end
            obj.propList(obj.selectedPropIndex) = [];
            if isempty(obj.propList)
                obj.selectedPropIndex = 0;
                obj.setPropPanelEnabled(false);
            else
                obj.selectedPropIndex = min(obj.selectedPropIndex, numel(obj.propList));
            end
            obj.refreshPropListBox();
            if obj.selectedPropIndex > 0
                obj.propListBox.Value = obj.selectedPropIndex;
                obj.loadPropToPanel(obj.selectedPropIndex);
            end
            obj.refreshDevicePropDropdown();
        end

        function onMovePropUp(obj)
            if obj.selectedPropIndex <= 1, return; end
            i = obj.selectedPropIndex;
            obj.propList([i-1, i]) = obj.propList([i, i-1]);
            obj.selectedPropIndex = i - 1;
            obj.refreshPropListBox();
            obj.propListBox.Value = obj.selectedPropIndex;
        end

        function onMovePropDown(obj)
            if obj.selectedPropIndex < 1 || obj.selectedPropIndex >= numel(obj.propList)
                return;
            end
            i = obj.selectedPropIndex;
            obj.propList([i, i+1]) = obj.propList([i+1, i]);
            obj.selectedPropIndex = i + 1;
            obj.refreshPropListBox();
            obj.propListBox.Value = obj.selectedPropIndex;
        end

        function onPropSelected(obj)
            if isempty(obj.propList)
                obj.selectedPropIndex = 0;
                obj.setPropPanelEnabled(false);
                return;
            end
            idx = obj.propListBox.Value;  % numeric via ItemsData
            if isempty(idx) || ~isnumeric(idx) || idx < 1 || idx > numel(obj.propList)
                return;
            end
            if obj.selectedPropIndex > 0 && obj.selectedPropIndex <= numel(obj.propList)
                obj.savePanelToProp(obj.selectedPropIndex);
            end
            obj.selectedPropIndex = idx;
            obj.loadPropToPanel(idx);
            obj.setPropPanelEnabled(true);
            obj.tabGroup.SelectedTab = obj.tabGroup.Children(1);
        end

        function refreshPropListBox(obj)
            items = cell(1, numel(obj.propList));
            for i = 1:numel(obj.propList)
                p = obj.propList{i};
                if strcmp(p.matlabType, 'device')
                    tag = ' [device]';
                elseif ~isempty(p.domain)
                    tag = ' [enum]';
                else
                    tag = '';
                end
                items{i} = sprintf('%s (%s)%s', p.name, p.matlabType, tag);
            end
            obj.propListBox.Items = items;
            obj.propListBox.ItemsData = 1:numel(items);
        end

        % ============================================================
        % Property detail: load / save
        % ============================================================
        function loadPropToPanel(obj, idx)
            p = obj.propList{idx};
            obj.propNameField.Value = p.name;
            obj.propDefaultField.Value = p.defaultValue;
            obj.propDomainField.Value = p.domain;
            obj.propDescriptionField.Value = p.description;
            obj.propCategoryField.Value = p.category;

            isDevice = strcmp(p.matlabType, 'device');
            obj.propIsDeviceCheck.Value = isDevice;
            if isDevice
                obj.propTypeDropdown.Value = 'device';
                obj.propDefaultField.Enable = 'off';
                obj.propDomainField.Enable = 'off';
            else
                obj.propTypeDropdown.Value = p.matlabType;
                obj.propDefaultField.Enable = 'on';
                obj.propDomainField.Enable = 'on';
            end
        end

        function savePanelToProp(obj, idx)
            p = obj.propList{idx};
            p.name = strtrim(obj.propNameField.Value);
            p.defaultValue = strtrim(obj.propDefaultField.Value);
            p.domain = strtrim(obj.propDomainField.Value);
            p.description = strtrim(obj.propDescriptionField.Value);
            p.category = strtrim(obj.propCategoryField.Value);

            if obj.propIsDeviceCheck.Value
                p.matlabType = 'device';
            else
                p.matlabType = obj.propTypeDropdown.Value;
            end
            obj.propList{idx} = p;
            obj.refreshPropListBox();
            if idx <= numel(obj.propList)
                obj.propListBox.Value = idx;
            end
        end

        function onPropFieldChanged(obj)
            if obj.selectedPropIndex > 0 && obj.selectedPropIndex <= numel(obj.propList)
                obj.savePanelToProp(obj.selectedPropIndex);
                obj.refreshDevicePropDropdown();
            end
        end

        function onPropDeviceToggle(obj)
            isDevice = obj.propIsDeviceCheck.Value;
            if isDevice
                obj.propTypeDropdown.Value = 'device';
                obj.propDefaultField.Enable = 'off';
                obj.propDefaultField.Value = '';
                obj.propDomainField.Enable = 'off';
                obj.propDomainField.Value = '';
            else
                obj.propTypeDropdown.Value = 'double';
                obj.propDefaultField.Enable = 'on';
                obj.propDomainField.Enable = 'on';
            end
            obj.onPropFieldChanged();
        end

        % ============================================================
        % Stimulus tab helpers
        % ============================================================
        function onGeneratorChanged(obj)
            obj.refreshGeneratorInfo();
        end

        function refreshGeneratorInfo(obj)
            gen = obj.stimGeneratorDropdown.Value;
            switch gen
                case 'PulseGenerator'
                    info = {
                        'PulseGenerator properties:'
                        '  preTime      - Leading duration (ms)'
                        '  stimTime     - Pulse duration (ms)'
                        '  tailTime     - Trailing duration (ms)'
                        '  amplitude    - Pulse amplitude (units)'
                        '  mean         - Mean / holding value'
                        '  sampleRate   - From protocol.sampleRate'
                        '  units        - From device background'
                        ''
                        'Mapped from protocol properties:'
                        '  preTime, stimTime, tailTime -> gen fields'
                        '  amplitude -> pulseAmplitude property'
                        '  mean, units -> device.background'
                        };
                case 'PulseTrainGenerator'
                    info = {
                        'PulseTrainGenerator properties:'
                        '  preTime, stimTime, tailTime'
                        '  amplitude, mean'
                        '  pulseNumber  - Number of pulses in train'
                        '  interpulseInterval - Gap between pulses'
                        '  sampleRate, units'
                        };
                case 'DirectCurrentGenerator'
                    info = {
                        'DirectCurrentGenerator properties:'
                        '  time    - Duration (s)'
                        '  offset  - Constant value (units)'
                        '  sampleRate, units'
                        };
                case 'SineGenerator'
                    info = {
                        'SineGenerator properties:'
                        '  preTime, stimTime, tailTime'
                        '  amplitude   - Peak amplitude'
                        '  period      - Oscillation period (ms)'
                        '  phase       - Phase offset (radians)'
                        '  mean        - DC offset'
                        '  sampleRate, units'
                        };
                case 'SquareGenerator'
                    info = {
                        'SquareGenerator properties:'
                        '  preTime, stimTime, tailTime'
                        '  amplitude   - Peak amplitude'
                        '  period      - Oscillation period (ms)'
                        '  phase       - Phase offset (radians)'
                        '  mean        - DC offset'
                        '  sampleRate, units'
                        };
                case 'RampGenerator'
                    info = {
                        'RampGenerator properties:'
                        '  preTime, stimTime, tailTime'
                        '  amplitude   - Ramp peak'
                        '  mean        - Baseline / holding'
                        '  sampleRate, units'
                        };
                case '(none)'
                    info = {
                        'No stimulus generator selected.'
                        'Protocol will only add responses (no stimulus).'
                        'Use this for recording-only protocols.'
                        };
                otherwise
                    info = {'Select a generator type.'};
            end
            obj.stimInfoArea.Value = info;
        end

        function refreshDevicePropDropdown(obj)
            % Update the stimulus device dropdown with all device-type properties
            devProps = {};
            for i = 1:numel(obj.propList)
                if strcmp(obj.propList{i}.matlabType, 'device')
                    devProps{end+1} = obj.propList{i}.name; %#ok<AGROW>
                end
            end
            if isempty(devProps)
                devProps = {'(none)'};
            end
            currentVal = obj.stimDevicePropDropdown.Value;
            obj.stimDevicePropDropdown.Items = devProps;
            if ismember(currentVal, devProps)
                obj.stimDevicePropDropdown.Value = currentVal;
            else
                obj.stimDevicePropDropdown.Value = devProps{1};
            end
        end

        % ============================================================
        % Code generation
        % ============================================================
        function code = generateCode(obj)
            % Save current property edits
            if obj.selectedPropIndex > 0 && obj.selectedPropIndex <= numel(obj.propList)
                obj.savePanelToProp(obj.selectedPropIndex);
            end

            className = strtrim(obj.classNameField.Value);
            baseClass = strtrim(obj.baseClassDropdown.Value);
            genType   = obj.stimGeneratorDropdown.Value;
            devProp   = obj.stimDevicePropDropdown.Value;
            if strcmp(devProp, '(none)'), devProp = ''; end
            nl = newline;
            I = '    '; I2 = '        '; I3 = '            ';

            lines = {};

            % --- classdef ---
            lines{end+1} = sprintf('classdef %s < %s', className, baseClass);
            lines{end+1} = '';

            % --- public properties ---
            lines{end+1} = [I 'properties'];
            deviceProps = {};
            for i = 1:numel(obj.propList)
                p = obj.propList{i};
                if strcmp(p.matlabType, 'device')
                    % Device property: no default, comment
                    comment = '';
                    if ~isempty(p.description)
                        comment = ['  % ' p.description];
                    end
                    lines{end+1} = sprintf('%s%s%s', I2, p.name, comment); %#ok<AGROW>
                    deviceProps{end+1} = p.name; %#ok<AGROW>
                else
                    defStr = obj.formatDefault(p);
                    comment = '';
                    if ~isempty(p.description)
                        comment = ['  % ' p.description];
                    end
                    lines{end+1} = sprintf('%s%s = %s%s', I2, p.name, defStr, comment); %#ok<AGROW>
                end
            end

            % numberOfAverages
            if obj.chkUseNumAverages.Value
                nAvg = obj.numAveragesDefault.Value;
                lines{end+1} = sprintf('%snumberOfAverages = uint16(%d)  %% Number of epochs', I2, nAvg);
            end

            % interpulseInterval
            if obj.chkInterpulse.Value
                ipd = obj.interpulseDefault.Value;
                lines{end+1} = sprintf('%sinterpulseInterval = %g  %% Duration between epochs (s)', I2, ipd);
            end

            lines{end+1} = [I 'end'];
            lines{end+1} = '';

            % --- hidden properties (types) ---
            hasHidden = ~isempty(deviceProps) || obj.hasTypedProps();
            if hasHidden
                lines{end+1} = [I 'properties (Hidden)'];
                for i = 1:numel(deviceProps)
                    lines{end+1} = sprintf('%s%sType', I2, deviceProps{i}); %#ok<AGROW>
                end
                for i = 1:numel(obj.propList)
                    p = obj.propList{i};
                    if ~strcmp(p.matlabType, 'device') && ~isempty(p.domain)
                        lines{end+1} = sprintf('%s%sType = %s', I2, p.name, ...
                            obj.buildPropertyTypeStr(p)); %#ok<AGROW>
                    end
                end
                lines{end+1} = [I 'end'];
                lines{end+1} = '';
            end

            % --- methods ---
            lines{end+1} = [I 'methods'];
            lines{end+1} = '';

            % didSetRig
            if ~isempty(deviceProps)
                lines{end+1} = sprintf('%sfunction didSetRig(obj)', I2);
                lines{end+1} = sprintf('%sdidSetRig@%s(obj);', I3, baseClass);
                for i = 1:numel(deviceProps)
                    dp = deviceProps{i};
                    expr = obj.getDeviceExpression(dp);
                    lines{end+1} = sprintf('%s[obj.%s, obj.%sType] = obj.createDeviceNamesProperty(''%s'');', ...
                        I3, dp, dp, expr); %#ok<AGROW>
                end
                lines{end+1} = sprintf('%send', I2);
                lines{end+1} = '';
            end

            % getPreview
            if ~strcmp(genType, '(none)') && ~isempty(devProp)
                lines{end+1} = sprintf('%sfunction p = getPreview(obj, panel)', I2);
                lines{end+1} = sprintf('%sp = symphonyui.builtin.previews.StimuliPreview(panel, @()obj.create%sStimulus());', ...
                    I3, obj.capitalize(devProp));
                lines{end+1} = sprintf('%send', I2);
                lines{end+1} = '';
            end

            % prepareRun
            lines{end+1} = sprintf('%sfunction prepareRun(obj)', I2);
            lines{end+1} = sprintf('%sprepareRun@%s(obj);', I3, baseClass);
            if ~isempty(devProp)
                lines = obj.appendFigureCode(lines, devProp, I3);
            end
            lines{end+1} = sprintf('%send', I2);
            lines{end+1} = '';

            % createStimulus helper
            if ~strcmp(genType, '(none)') && ~isempty(devProp)
                stimMethodName = sprintf('create%sStimulus', obj.capitalize(devProp));
                lines{end+1} = sprintf('%sfunction stim = %s(obj)', I2, stimMethodName);
                lines{end+1} = sprintf('%sgen = symphonyui.builtin.stimuli.%s();', I3, genType);
                lines = obj.appendGeneratorMappings(lines, genType, devProp, I3);
                lines{end+1} = sprintf('%sstim = gen.generate();', I3);
                lines{end+1} = sprintf('%send', I2);
                lines{end+1} = '';
            end

            % prepareEpoch
            lines{end+1} = sprintf('%sfunction prepareEpoch(obj, epoch)', I2);
            lines{end+1} = sprintf('%sprepareEpoch@%s(obj, epoch);', I3, baseClass);
            if ~strcmp(genType, '(none)') && ~isempty(devProp)
                lines{end+1} = sprintf('%sepoch.addStimulus(obj.rig.getDevice(obj.%s), obj.create%sStimulus());', ...
                    I3, devProp, obj.capitalize(devProp));
            end
            if ~isempty(devProp)
                lines{end+1} = sprintf('%sepoch.addResponse(obj.rig.getDevice(obj.%s));', I3, devProp);
            end
            lines{end+1} = sprintf('%send', I2);
            lines{end+1} = '';

            % prepareInterval
            if obj.chkInterpulse.Value && ~isempty(devProp)
                lines{end+1} = sprintf('%sfunction prepareInterval(obj, interval)', I2);
                lines{end+1} = sprintf('%sprepareInterval@%s(obj, interval);', I3, baseClass);
                lines{end+1} = sprintf('%sdevice = obj.rig.getDevice(obj.%s);', I3, devProp);
                lines{end+1} = sprintf('%sinterval.addDirectCurrentStimulus(device, device.background, obj.interpulseInterval, obj.sampleRate);', I3);
                lines{end+1} = sprintf('%send', I2);
                lines{end+1} = '';
            end

            % shouldContinuePreparingEpochs / shouldContinueRun
            if obj.chkUseNumAverages.Value
                lines{end+1} = sprintf('%sfunction tf = shouldContinuePreparingEpochs(obj)', I2);
                lines{end+1} = sprintf('%stf = obj.numEpochsPrepared < obj.numberOfAverages;', I3);
                lines{end+1} = sprintf('%send', I2);
                lines{end+1} = '';
                lines{end+1} = sprintf('%sfunction tf = shouldContinueRun(obj)', I2);
                lines{end+1} = sprintf('%stf = obj.numEpochsCompleted < obj.numberOfAverages;', I3);
                lines{end+1} = sprintf('%send', I2);
            end

            lines{end+1} = '';
            lines{end+1} = [I 'end'];
            lines{end+1} = '';
            lines{end+1} = 'end';
            lines{end+1} = '';

            code = strjoin(lines, nl);
        end

        function lines = appendFigureCode(obj, lines, devProp, I)
            devExpr = sprintf('obj.rig.getDevice(obj.%s)', devProp);

            if obj.chkResponse.Value
                lines{end+1} = sprintf('%sobj.showFigure(''symphonyui.builtin.figures.ResponseFigure'', %s);', I, devExpr);
            end

            if obj.chkMeanResponse.Value
                groupBy = strtrim(obj.meanGroupByField.Value);
                if isempty(groupBy)
                    lines{end+1} = sprintf('%sobj.showFigure(''symphonyui.builtin.figures.MeanResponseFigure'', %s);', I, devExpr);
                else
                    lines{end+1} = sprintf('%sobj.showFigure(''symphonyui.builtin.figures.MeanResponseFigure'', %s, ...', I, devExpr);
                    lines{end+1} = sprintf('%s    ''groupBy'', {''%s''});', I, groupBy);
                end
            end

            if obj.chkResponseStats.Value
                bline = strtrim(obj.statsBaselineField.Value);
                meas  = strtrim(obj.statsMeasureField.Value);
                lines{end+1} = sprintf('%sobj.showFigure(''symphonyui.builtin.figures.ResponseStatisticsFigure'', %s, {@mean, @var}, ...', I, devExpr);
                lines{end+1} = sprintf('%s    ''baselineRegion'', %s, ...', I, bline);
                lines{end+1} = sprintf('%s    ''measurementRegion'', %s);', I, meas);
            end

            if obj.chkCustom.Value
                lines{end+1} = sprintf('%s%% TODO: implement custom figure handler', I);
                lines{end+1} = sprintf('%s%% obj.showFigure(''symphonyui.builtin.figures.CustomFigure'', @obj.updateCustomFigure);', I);
            end
        end

        function lines = appendGeneratorMappings(obj, lines, genType, devProp, I)
            devBgQ = sprintf('obj.rig.getDevice(obj.%s).background.quantity', devProp);
            devBgU = sprintf('obj.rig.getDevice(obj.%s).background.displayUnits', devProp);

            switch genType
                case 'PulseGenerator'
                    lines{end+1} = sprintf('%sgen.preTime = obj.preTime;', I);
                    lines{end+1} = sprintf('%sgen.stimTime = obj.stimTime;', I);
                    lines{end+1} = sprintf('%sgen.tailTime = obj.tailTime;', I);
                    if obj.hasProp('pulseAmplitude')
                        lines{end+1} = sprintf('%sgen.amplitude = obj.pulseAmplitude;', I);
                    else
                        lines{end+1} = sprintf('%sgen.amplitude = 100;  %% TODO: map to a property', I);
                    end
                    lines{end+1} = sprintf('%sgen.mean = %s;', I, devBgQ);
                    lines{end+1} = sprintf('%sgen.sampleRate = obj.sampleRate;', I);
                    lines{end+1} = sprintf('%sgen.units = %s;', I, devBgU);

                case 'PulseTrainGenerator'
                    lines{end+1} = sprintf('%sgen.preTime = obj.preTime;', I);
                    lines{end+1} = sprintf('%sgen.stimTime = obj.stimTime;', I);
                    lines{end+1} = sprintf('%sgen.tailTime = obj.tailTime;', I);
                    lines{end+1} = sprintf('%sgen.amplitude = 100;  %% TODO: map to a property', I);
                    lines{end+1} = sprintf('%sgen.mean = %s;', I, devBgQ);
                    lines{end+1} = sprintf('%sgen.pulseNumber = 5;  %% TODO: map to a property', I);
                    lines{end+1} = sprintf('%sgen.interpulseInterval = 0;  %% TODO: map to a property', I);
                    lines{end+1} = sprintf('%sgen.sampleRate = obj.sampleRate;', I);
                    lines{end+1} = sprintf('%sgen.units = %s;', I, devBgU);

                case 'DirectCurrentGenerator'
                    lines{end+1} = sprintf('%sgen.time = (obj.preTime + obj.stimTime + obj.tailTime) / 1e3;', I);
                    lines{end+1} = sprintf('%sgen.offset = %s;', I, devBgQ);
                    lines{end+1} = sprintf('%sgen.sampleRate = obj.sampleRate;', I);
                    lines{end+1} = sprintf('%sgen.units = %s;', I, devBgU);

                case {'SineGenerator', 'SquareGenerator'}
                    lines{end+1} = sprintf('%sgen.preTime = obj.preTime;', I);
                    lines{end+1} = sprintf('%sgen.stimTime = obj.stimTime;', I);
                    lines{end+1} = sprintf('%sgen.tailTime = obj.tailTime;', I);
                    lines{end+1} = sprintf('%sgen.amplitude = 100;  %% TODO: map to a property', I);
                    lines{end+1} = sprintf('%sgen.period = 100;  %% TODO: map to a property (ms)', I);
                    lines{end+1} = sprintf('%sgen.phase = 0;', I);
                    lines{end+1} = sprintf('%sgen.mean = %s;', I, devBgQ);
                    lines{end+1} = sprintf('%sgen.sampleRate = obj.sampleRate;', I);
                    lines{end+1} = sprintf('%sgen.units = %s;', I, devBgU);

                case 'RampGenerator'
                    lines{end+1} = sprintf('%sgen.preTime = obj.preTime;', I);
                    lines{end+1} = sprintf('%sgen.stimTime = obj.stimTime;', I);
                    lines{end+1} = sprintf('%sgen.tailTime = obj.tailTime;', I);
                    lines{end+1} = sprintf('%sgen.amplitude = 100;  %% TODO: map to a property', I);
                    lines{end+1} = sprintf('%sgen.mean = %s;', I, devBgQ);
                    lines{end+1} = sprintf('%sgen.sampleRate = obj.sampleRate;', I);
                    lines{end+1} = sprintf('%sgen.units = %s;', I, devBgU);
            end
        end

        % ============================================================
        % Preview / Generate
        % ============================================================
        function onPreviewCode(obj)
            code = obj.generateCode();

            prevFig = uifigure('Name', 'Generated Protocol Code', ...
                'Position', [150 100 720 540]);
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
            className = strtrim(obj.classNameField.Value);
            if isempty(className) || ~isvarname(className)
                uialert(obj.fig, 'Enter a valid MATLAB class name.', 'Generate');
                return;
            end

            code = obj.generateCode();

            outDir = strtrim(obj.outputDirField.Value);
            pkgPath = strtrim(obj.packageField.Value);
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

            uialert(obj.fig, sprintf('Protocol saved to:\n%s', filePath), 'Success', 'Icon', 'success');
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

        function setPropPanelEnabled(obj, tf)
            if tf, state = 'on'; else, state = 'off'; end
            obj.propNameField.Enable = state;
            obj.propTypeDropdown.Enable = state;
            obj.propDefaultField.Enable = state;
            obj.propDomainField.Enable = state;
            obj.propDescriptionField.Enable = state;
            obj.propCategoryField.Enable = state;
            obj.propIsDeviceCheck.Enable = state;
        end

        % ============================================================
        % Helpers
        % ============================================================
        function tf = hasProp(obj, name)
            tf = false;
            for i = 1:numel(obj.propList)
                if strcmp(obj.propList{i}.name, name)
                    tf = true;
                    return;
                end
            end
        end

        function tf = hasTypedProps(obj)
            tf = false;
            for i = 1:numel(obj.propList)
                p = obj.propList{i};
                if ~strcmp(p.matlabType, 'device') && ~isempty(p.domain)
                    tf = true;
                    return;
                end
            end
        end

        function expr = getDeviceExpression(~, propName)
            % Convert property name to the rig expression string
            % 'amp' -> 'Amp', 'led' -> 'Led'
            expr = [upper(propName(1)), propName(2:end)];
        end

    end

    % ================================================================
    % Static helpers
    % ================================================================
    methods (Static, Access = private)

        function p = makeProp(name, matlabType, defaultValue, domain, description, category)
            p = struct( ...
                'name', name, ...
                'matlabType', matlabType, ...
                'defaultValue', defaultValue, ...
                'domain', domain, ...
                'description', description, ...
                'category', category);
        end

        function s = formatDefault(p)
            switch p.matlabType
                case 'double'
                    if isempty(p.defaultValue)
                        s = '0';
                    else
                        s = p.defaultValue;
                    end
                case 'int32'
                    val = p.defaultValue;
                    if isempty(val), val = '0'; end
                    s = sprintf('int32(%s)', val);
                case 'uint16'
                    val = p.defaultValue;
                    if isempty(val), val = '0'; end
                    s = sprintf('uint16(%s)', val);
                case 'logical'
                    val = p.defaultValue;
                    if isempty(val), val = 'true'; end
                    s = val;
                case 'char'
                    val = p.defaultValue;
                    if isempty(val), val = ''; end
                    s = sprintf('''%s''', val);
                case 'cellstr'
                    val = p.defaultValue;
                    if isempty(val), val = '{}'; end
                    s = val;
                otherwise
                    s = p.defaultValue;
            end
        end

        function s = buildPropertyTypeStr(p)
            % Build symphonyui.core.PropertyType(...) string
            switch p.matlabType
                case {'double', 'int32', 'uint16'}
                    prim = p.matlabType;
                    if prim(1) == 'd'
                        prim = 'denserealdouble';
                    end
                    % Check if domain looks like a range [lo hi] or enum
                    dom = strtrim(p.domain);
                    if ~isempty(dom) && dom(1) == '['
                        s = sprintf('symphonyui.core.PropertyType(''%s'', ''scalar'', %s)', prim, dom);
                    elseif ~isempty(dom) && dom(1) == '{'
                        s = sprintf('symphonyui.core.PropertyType(''%s'', ''scalar'', %s)', prim, dom);
                    else
                        s = sprintf('symphonyui.core.PropertyType(''%s'', ''scalar'', {%s})', prim, dom);
                    end
                case 'char'
                    dom = strtrim(p.domain);
                    if ~isempty(dom) && dom(1) == '{'
                        s = sprintf('symphonyui.core.PropertyType(''char'', ''row'', %s)', dom);
                    else
                        parts = strsplit(dom, ',');
                        parts = cellfun(@strtrim, parts, 'UniformOutput', false);
                        parts(cellfun(@isempty, parts)) = [];
                        quoted = cellfun(@(v) sprintf('''%s''', v), parts, 'UniformOutput', false);
                        s = sprintf('symphonyui.core.PropertyType(''char'', ''row'', {%s})', strjoin(quoted, ', '));
                    end
                case 'cellstr'
                    dom = strtrim(p.domain);
                    if ~isempty(dom) && dom(1) == '{'
                        s = sprintf('symphonyui.core.PropertyType(''cellstr'', ''row'', %s)', dom);
                    else
                        parts = strsplit(dom, ',');
                        parts = cellfun(@strtrim, parts, 'UniformOutput', false);
                        parts(cellfun(@isempty, parts)) = [];
                        quoted = cellfun(@(v) sprintf('''%s''', v), parts, 'UniformOutput', false);
                        s = sprintf('symphonyui.core.PropertyType(''cellstr'', ''row'', {%s})', strjoin(quoted, ', '));
                    end
                otherwise
                    s = 'symphonyui.core.PropertyType()';
            end
        end

        function s = capitalize(str)
            if isempty(str)
                s = str;
            else
                s = [upper(str(1)), str(2:end)];
            end
        end
    end

end
