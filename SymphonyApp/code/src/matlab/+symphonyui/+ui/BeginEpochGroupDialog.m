classdef BeginEpochGroupDialog < handle
    %BEGINEPOCHGROUPDIALOG  Document → Begin Epoch Group (uifigure modal dialog).
    %   Scans Options search paths for EpochGroupDescription subclasses
    %   (e.g. Control, Drug, Wash in +epochgroups packages) and lets the
    %   user select one before beginning the group via the C# AcquisitionHost.

    properties (Access = private)
        fig matlab.ui.Figure
        parentFigure
        host  % IAcquisitionHost (.NET)
        result  % true if group begun, [] if cancelled

        descDropdown matlab.ui.control.DropDown
        labelField matlab.ui.control.EditField
        sourceDropdown matlab.ui.control.DropDown
        carryForwardCheckbox matlab.ui.control.CheckBox
        beginButton matlab.ui.control.Button
        cancelButton matlab.ui.control.Button

        descIds  % cell array of epoch-group class names (parallel to descDropdown.Items)
        sourceIds  % cell array of source ID strings
        typedLabel = ''  % Captures label text as user types (before Enter commits)
        searchPaths  % cell array of directories to scan
    end

    methods (Static)
        function result = showBlocking(parentFigure, host, searchPaths)
            %SHOWBLOCKING  Open modal Begin Epoch Group dialog and block until done.
            if nargin < 3
                searchPaths = {};
            end
            dlg = symphonyui.ui.BeginEpochGroupDialog(parentFigure, host, searchPaths);
            dlg.fig.Visible = 'on';
            uiwait(dlg.fig);
            result = dlg.result;
        end
    end

    methods (Access = private)
        function obj = BeginEpochGroupDialog(parentFigure, host, searchPaths)
            obj.parentFigure = parentFigure;
            obj.host = host;
            obj.searchPaths = searchPaths;
            obj.result = [];
            obj.descIds = {};
            obj.sourceIds = {};
            obj.buildUi();
            obj.populateDescriptions();
            obj.populateSources();
        end

        function buildUi(obj)
            w = 380;
            h = 230;
            pos = obj.centerOnParent(w, h);

            obj.fig = uifigure( ...
                'Name', 'Begin Epoch Group', ...
                'Position', pos, ...
                'WindowStyle', 'modal', ...
                'Color', [0.94 0.94 0.94], ...
                'Resize', 'off', ...
                'CloseRequestFcn', @(~,~)obj.onCancel(), ...
                'KeyPressFcn', @(~,e)obj.onKeyPress(e), ...
                'WindowKeyPressFcn', @(~,e)obj.onKeyPress(e));

            main = uigridlayout(obj.fig, [5 2]);
            main.RowHeight = {28, 28, 28, 28, 40};
            main.ColumnWidth = {90, '1x'};
            main.Padding = [12 12 12 12];
            main.RowSpacing = 8;
            main.ColumnSpacing = 8;

            % Row 1: Description (epoch group type)
            lbl0 = uilabel(main, 'Text', 'Description:', 'HorizontalAlignment', 'right');
            lbl0.Layout.Row = 1; lbl0.Layout.Column = 1;
            obj.descDropdown = uidropdown(main, 'Items', {'(loading...)'}, ...
                'ValueChangedFcn', @(~,~)obj.onDescriptionChanged());
            obj.descDropdown.Layout.Row = 1; obj.descDropdown.Layout.Column = 2;

            % Row 2: Label (auto-populated from description, editable)
            lbl1 = uilabel(main, 'Text', 'Label:', 'HorizontalAlignment', 'right');
            lbl1.Layout.Row = 2; lbl1.Layout.Column = 1;
            obj.labelField = uieditfield(main, 'text', 'Value', '', ...
                'ValueChangingFcn', @(~,e)obj.onLabelTyping(e));
            obj.labelField.Layout.Row = 2; obj.labelField.Layout.Column = 2;

            % Row 3: Source
            lbl2 = uilabel(main, 'Text', 'Source:', 'HorizontalAlignment', 'right');
            lbl2.Layout.Row = 3; lbl2.Layout.Column = 1;
            obj.sourceDropdown = uidropdown(main, 'Items', {'(loading...)'});
            obj.sourceDropdown.Layout.Row = 3; obj.sourceDropdown.Layout.Column = 2;

            % Row 4: Carry forward checkbox
            obj.carryForwardCheckbox = uicheckbox(main, ...
                'Text', 'Carry forward properties from last epoch group', ...
                'Value', true);
            obj.carryForwardCheckbox.Layout.Row = 4;
            obj.carryForwardCheckbox.Layout.Column = [1 2];

            % Row 5: Buttons
            btnGrid = uigridlayout(main, [1 3]);
            btnGrid.Layout.Row = 5;
            btnGrid.Layout.Column = [1 2];
            btnGrid.ColumnWidth = {'1x', 80, 80};
            btnGrid.Padding = [0 0 0 0];

            uilabel(btnGrid, 'Text', '');  % spacer
            obj.beginButton = uibutton(btnGrid, 'Text', 'Begin', ...
                'ButtonPushedFcn', @(~,~)obj.onBegin());
            obj.cancelButton = uibutton(btnGrid, 'Text', 'Cancel', ...
                'ButtonPushedFcn', @(~,~)obj.onCancel());

            % Propagate Enter/Escape from child controls to the dialog
            symphonyui.ui.DialogUtil.setKeyPressFcnRecursive(obj.fig, @(~,e)obj.onKeyPress(e));
        end

        function populateDescriptions(obj)
            try
                groups = symphonyui.ui.ProtocolScanner.discoverEpochGroups(obj.searchPaths);
                n = numel(groups);
                if n == 0
                    obj.descDropdown.Items = {'(no epoch groups available)'};
                    obj.descIds = {};
                    obj.beginButton.Enable = 'off';
                    return;
                end
                labels = cell(1, n);
                ids = cell(1, n);
                for i = 1:n
                    labels{i} = groups(i).displayName;
                    ids{i} = groups(i).id;
                end
                obj.descDropdown.Items = labels;
                obj.descIds = ids;
                % Auto-populate label from first description
                obj.onDescriptionChanged();
            catch ex
                fprintf(2, '\n=== Begin Epoch Group: Description Error ===\n%s\n', getReport(ex, 'extended'));
                obj.descDropdown.Items = {'(error loading epoch groups)'};
                obj.descIds = {};
                obj.beginButton.Enable = 'off';
            end
        end

        function onDescriptionChanged(obj)
            % Set the label field to the humanized name of the selected description
            idx = find(strcmp(obj.descDropdown.Items, obj.descDropdown.Value), 1);
            if ~isempty(idx) && idx >= 1 && idx <= numel(obj.descIds)
                className = obj.descIds{idx};
                try
                    ctorFcn = str2func(className);
                    desc = ctorFcn();
                    obj.labelField.Value = desc.label;
                catch
                    % Fallback: use display name
                    obj.labelField.Value = obj.descDropdown.Value;
                end
                % Reset typed label — the description just set it programmatically
                obj.typedLabel = obj.labelField.Value;
            end
        end

        function onLabelTyping(obj, event)
            % Capture text as the user types. ValueChangingFcn fires on
            % every keystroke with the current field text in event.Value.
            % This bypasses the UIFigure timing issue where KeyPressFcn
            % fires before uieditfield commits typed text to .Value.
            obj.typedLabel = event.Value;
        end

        function populateSources(obj)
            try
                dm = obj.host.GetDataManagerStateAsync().GetAwaiter().GetResult();
                sources = dm.Sources;
                n = SymphonyAppUtil.getNetCount(sources);
                if n == 0
                    obj.sourceDropdown.Items = {'(no sources)'};
                    obj.sourceIds = {};
                else
                    labels = cell(1, n);
                    ids = cell(1, n);
                    parentIds = cell(1, n);
                    for i = 1:n
                        s = SymphonyAppUtil.getNetItem(sources, i);
                        lbl = char(s.Label);
                        if isempty(lbl)
                            lbl = sprintf('Source %d', i);
                        end
                        labels{i} = lbl;
                        ids{i} = char(s.Id);
                        pid = s.ParentSourceId;
                        if isempty(pid)
                            parentIds{i} = '';
                        else
                            parentIds{i} = char(pid);
                        end
                    end
                    obj.sourceDropdown.Items = labels;
                    obj.sourceIds = ids;

                    % Default to the deepest (leaf) source — one whose Id
                    % is not the ParentSourceId of any other source.
                    leafIdx = [];
                    for i = 1:n
                        isParent = false;
                        for j = 1:n
                            if strcmp(ids{i}, parentIds{j})
                                isParent = true;
                                break;
                            end
                        end
                        if ~isParent
                            leafIdx = i;
                        end
                    end
                    if ~isempty(leafIdx)
                        obj.sourceDropdown.Value = labels{leafIdx};
                    end
                end
            catch ex
                obj.sourceDropdown.Items = {'(error loading sources)'};
                obj.sourceIds = {};
                fprintf(2, '\n=== Begin Epoch Group: Source Error ===\n%s\n', getReport(ex, 'extended'));
            end
        end

        function onBegin(obj)
            % Use the captured typed text if available. In UIFigure,
            % KeyPressFcn fires BEFORE uieditfield commits the typed text
            % to .Value, so reading .Value gives the stale pre-edit value.
            % ValueChangingFcn captures each keystroke into typedLabel.
            if ~isempty(obj.typedLabel)
                label = strtrim(obj.typedLabel);
            else
                label = strtrim(obj.labelField.Value);
            end
            if isempty(label)
                uialert(obj.fig, 'Please enter a label.', 'Begin Epoch Group');
                return;
            end

            % Resolve selected source ID
            sourceId = '';
            if ~isempty(obj.sourceIds)
                idx = find(strcmp(obj.sourceDropdown.Items, obj.sourceDropdown.Value), 1);
                if ~isempty(idx) && idx >= 1 && idx <= numel(obj.sourceIds)
                    sourceId = obj.sourceIds{idx};
                end
            end

            % Resolve selected description ID
            selectedDescId = '';
            if ~isempty(obj.descIds)
                dIdx = find(strcmp(obj.descDropdown.Items, obj.descDropdown.Value), 1);
                if ~isempty(dIdx) && dIdx >= 1 && dIdx <= numel(obj.descIds)
                    selectedDescId = obj.descIds{dIdx};
                end
            end

            try
                if isempty(sourceId)
                    obj.host.BeginEpochGroupAsync(label).GetAwaiter().GetResult();
                else
                    obj.host.BeginEpochGroupAsync(label, sourceId).GetAwaiter().GetResult();
                end

                % Write epoch group description properties to HDF5
                carryForward = obj.carryForwardCheckbox.Value;
                if ~isempty(selectedDescId)
                    try
                        obj.writeEpochGroupDescriptionProps(selectedDescId, carryForward);
                    catch propEx
                        fprintf(2, 'Warning: failed to write epoch group description properties: %s\n', propEx.message);
                    end
                end

                obj.result = true;
                obj.closeDialog();
            catch ex
                fprintf(2, '\n=== Begin Epoch Group Error ===\n%s\n', getReport(ex, 'extended'));
                uialert(obj.fig, ex.message, 'Begin Epoch Group Error');
            end
        end

        function writeEpochGroupDescriptionProps(obj, descId, carryForward)
            %WRITEEPOCHGROUPDESCRIPTIONPROPS  Write description properties
            %   to the most recently created epoch group in HDF5.
            %   If carryForward is true, overwrite defaults with values from
            %   the previous epoch group.
            if nargin < 3
                carryForward = false;
            end

            try
                descInst = feval(str2func(descId));
            catch
                return;
            end

            % Get the persistor and find the current epoch group
            try
                cper = obj.host.GetPersistor();
                if isempty(cper), return; end
            catch
                return;
            end

            pEG = [];
            try
                eg = cper.CurrentEpochGroup;
                if ~isempty(eg)
                    pEG = eg;
                end
            catch egEx
                fprintf(2, 'writeEGDescProps: failed to get CurrentEpochGroup: %s\n', egEx.message);
            end
            if isempty(pEG)
                fprintf(2, 'writeEGDescProps: pEG is empty, returning\n');
                return;
            end

            % Write the description type ID as a property
            try
                pEG.AddProperty('__epochGroupDescriptionId', descId);
            catch resEx
                fprintf(2, 'writeEGDescProps: AddProperty(__epochGroupDescriptionId) failed: %s\n', resEx.message);
            end

            % Write description properties from PropertyDescriptors
            descList = descInst.getPropertyDescriptors();
            for k = 1:numel(descList)
                d = descList(k);
                propName = d.name;
                propVal = d.value;
                try
                    if iscell(propVal)
                        valToWrite = strjoin(cellfun(@char, propVal, 'UniformOutput', false), ';');
                    elseif isnumeric(propVal)
                        valToWrite = num2str(propVal);
                    else
                        valToWrite = char(string(propVal));
                    end
                    pEG.AddProperty(propName, valToWrite);
                catch propWriteEx
                    fprintf(2, '  FAILED to write prop "%s": %s\n', propName, propWriteEx.message);
                end
            end

            % Carry forward properties from the previous epoch group
            if carryForward
                try
                    obj.carryForwardFromPreviousEpochGroup(cper, pEG);
                catch cfEx
                    fprintf(2, 'writeEGDescProps: carry-forward failed: %s\n', cfEx.message);
                end
            end
        end

        function carryForwardFromPreviousEpochGroup(~, cper, currentEG)
            %CARRYFORWARDFROMPREVIOUSEPOCHGROUP  Copy property values from
            %   the epoch group created before the current one.
            try
                allGroups = cper.Experiment.EpochGroupsList();
                nGroups = allGroups.Count;
                if nGroups < 2
                    return;
                end

                % The current epoch group is the last one; the previous is second-to-last
                prevEG = allGroups.Item(nGroups - 2);  % 0-indexed .NET list

                % Read properties from the previous epoch group
                prevProps = prevEG.PropertiesList();
                nProps = prevProps.Count;
                for k = 0:(nProps - 1)  % 0-indexed .NET list
                    kv = prevProps.Item(k);
                    propName = char(kv.Key);
                    propVal = char(string(kv.Value));
                    % Skip internal properties
                    if startsWith(propName, '__')
                        continue;
                    end
                    try
                        currentEG.AddProperty(propName, propVal);
                    catch
                        % AddProperty may fail if key already exists; try remove then add
                        try
                            currentEG.RemoveProperty(propName);
                            currentEG.AddProperty(propName, propVal);
                        catch replaceEx
                            fprintf(2, '  FAILED to carry forward "%s": %s\n', propName, replaceEx.message);
                        end
                    end
                end
            catch ex
                fprintf(2, 'carryForwardFromPreviousEpochGroup error: %s\n', ex.message);
            end
        end

        function onCancel(obj)
            obj.result = [];
            obj.closeDialog();
        end

        function onKeyPress(obj, event)
            switch event.Key
                case 'return'
                    obj.onBegin();
                case 'escape'
                    obj.onCancel();
            end
        end

        function closeDialog(obj)
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

end
