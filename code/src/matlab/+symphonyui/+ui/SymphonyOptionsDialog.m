classdef SymphonyOptionsDialog < handle
    %SYMPHONYOPTIONSDIALOG  Configure → Options (uifigure), aligned with symphonyui.ui.views.OptionsView.
    %   Sections use uitabgroup (not stacked uipanels — avoids uifigure paint bugs). Persists via
    %   symphonyui.app.Options (appbox.Settings / getpref). Same behavior as OptionsPresenter.

    properties (Access = private)
        fig matlab.ui.Figure
        parentFigure matlab.ui.Figure
        options % symphonyui.app.Options
        tabGroup matlab.ui.container.TabGroup
        % General
        startupFileField matlab.ui.control.EditField
        cleanupFileField matlab.ui.control.EditField
        browseStartupButton matlab.ui.control.Button
        browseCleanupButton matlab.ui.control.Button
        warnViewOnlyCheck matlab.ui.control.CheckBox
        % File
        defaultNameField matlab.ui.control.EditField
        defaultLocationField matlab.ui.control.EditField
        cleanupFunctionField matlab.ui.control.EditField
        browseDefaultLocationButton matlab.ui.control.Button
        % Search path
        searchPathList matlab.ui.control.ListBox
        addPathButton matlab.ui.control.Button
        removePathButton matlab.ui.control.Button
        excludeField matlab.ui.control.EditField
        excludeHelpButton matlab.ui.control.Button
        % Logging
        loggingConfigField matlab.ui.control.EditField
        loggingDirField matlab.ui.control.EditField
        browseLoggingConfigButton matlab.ui.control.Button
        browseLoggingDirButton matlab.ui.control.Button
        % Streaming
        streamingEnabledCheck matlab.ui.control.CheckBox
        streamingThresholdField matlab.ui.control.EditField
        streamingMaxChunksField matlab.ui.control.EditField
        streamingTimeLabel matlab.ui.control.Label
        % Footer
        saveButton matlab.ui.control.Button
        defaultButton matlab.ui.control.Button
        cancelButton matlab.ui.control.Button
    end

    methods (Static)
        function showBlocking(parentFigure)
            % Open modal Options dialog and block until Save, Default (reset), or Cancel/Close.
            if nargin < 1
                parentFigure = [];
            end
            dlg = symphonyui.ui.SymphonyOptionsDialog(parentFigure);
            dlg.fig.Visible = 'on';
            uiwait(dlg.fig);
        end
    end

    methods (Access = private)
        function obj = SymphonyOptionsDialog(parentFigure)
            obj.parentFigure = parentFigure;
            obj.options = symphonyui.app.Options.getDefault();
            obj.buildUi();
            obj.populateFromOptions();
        end

        function buildUi(obj)
            w = 580;
            h = 460;
            % Restore saved position, or center on parent
            pos = obj.centerOnParent(w, h);
            try
                savedPos = getpref('SymphonyUI', 'OptionsDialogPosition', []);
                if ~isempty(savedPos) && numel(savedPos) == 4
                    pos = [savedPos(1) savedPos(2) w h];
                end
            catch
            end

            obj.fig = uifigure( ...
                'Name', 'Options', ...
                'Position', pos, ...
                'WindowStyle', 'modal', ...
                'Color', [0.94 0.94 0.94], ...
                'CloseRequestFcn', @(~,~)obj.onCloseRequest(), ...
                'KeyPressFcn', @(~,e)obj.onKeyPress(e));

            main = uigridlayout(obj.fig, [2 1]);
            main.RowHeight = {'1x', 40};
            main.Padding = [10 10 10 10];
            main.RowSpacing = 10;

            % Use left tabs instead of list + stacked uipanels — uifigure often fails to paint
            % overlapping normalized panels correctly (same class of issue as Data Manager cards).
            body = uigridlayout(main, [1 1]);
            body.Layout.Row = 1;
            body.Layout.Column = 1;
            body.Padding = [0 0 0 0];

            try
                obj.tabGroup = uitabgroup(body, 'TabLocation', 'left');
            catch
                obj.tabGroup = uitabgroup(body, 'TabLocation', 'top');
            end
            obj.tabGroup.Layout.Row = 1;
            obj.tabGroup.Layout.Column = 1;

            tabGeneral = uitab(obj.tabGroup, 'Title', 'General');
            tabFile = uitab(obj.tabGroup, 'Title', 'File');
            tabSearch = uitab(obj.tabGroup, 'Title', 'Search Path');
            tabLogging = uitab(obj.tabGroup, 'Title', 'Logging');
            tabStreaming = uitab(obj.tabGroup, 'Title', 'Streaming');

            obj.buildGeneralCard(tabGeneral);
            obj.buildFileCard(tabFile);
            obj.buildSearchCard(tabSearch);
            obj.buildLoggingCard(tabLogging);
            obj.buildStreamingCard(tabStreaming);

            foot = uigridlayout(main, [1 4]);
            foot.Layout.Row = 2;
            foot.Layout.Column = 1;
            foot.ColumnWidth = {'1x', 80, 80, 80};
            foot.Padding = [0 0 0 0];
            foot.ColumnSpacing = 8;

            sp = uilabel(foot, 'Text', '');
            sp.Layout.Row = 1;
            sp.Layout.Column = 1;
            obj.saveButton = uibutton(foot, 'Text', 'Save', 'ButtonPushedFcn', @(~,~)obj.onSave());
            obj.saveButton.Layout.Row = 1;
            obj.saveButton.Layout.Column = 2;
            obj.defaultButton = uibutton(foot, 'Text', 'Default', 'ButtonPushedFcn', @(~,~)obj.onDefault());
            obj.defaultButton.Layout.Row = 1;
            obj.defaultButton.Layout.Column = 3;
            obj.cancelButton = uibutton(foot, 'Text', 'Cancel', 'ButtonPushedFcn', @(~,~)obj.onCancel());
            obj.cancelButton.Layout.Row = 1;
            obj.cancelButton.Layout.Column = 4;

            symphonyui.ui.DialogUtil.setKeyPressFcnRecursive(obj.fig, @(~,e)obj.onKeyPress(e));
        end

        function buildGeneralCard(obj, tab)
            g = uigridlayout(tab, [3 3]);
            g.Padding = [8 8 8 8];
            g.RowHeight = {24, 24, 24};
            g.ColumnWidth = {88, '1x', 36};
            g.RowSpacing = 6;
            g.ColumnSpacing = 6;

            L1 = uilabel(g, 'Text', 'Startup file:', 'HorizontalAlignment', 'right');
            L1.Layout.Row = 1;
            L1.Layout.Column = 1;
            obj.startupFileField = uieditfield(g, 'Editable', 'on');
            obj.startupFileField.Layout.Row = 1;
            obj.startupFileField.Layout.Column = 2;
            obj.browseStartupButton = uibutton(g, 'Text', '...', 'Tooltip', 'Browse', ...
                'ButtonPushedFcn', @(~,~)obj.browseStartup());
            obj.browseStartupButton.Layout.Row = 1;
            obj.browseStartupButton.Layout.Column = 3;
            L2 = uilabel(g, 'Text', 'Cleanup file:', 'HorizontalAlignment', 'right');
            L2.Layout.Row = 2;
            L2.Layout.Column = 1;
            obj.cleanupFileField = uieditfield(g, 'Editable', 'on');
            obj.cleanupFileField.Layout.Row = 2;
            obj.cleanupFileField.Layout.Column = 2;
            obj.browseCleanupButton = uibutton(g, 'Text', '...', 'Tooltip', 'Browse', ...
                'ButtonPushedFcn', @(~,~)obj.browseCleanup());
            obj.browseCleanupButton.Layout.Row = 2;
            obj.browseCleanupButton.Layout.Column = 3;
            obj.warnViewOnlyCheck = uicheckbox(g, 'Text', 'Show warning before running "View Only" with an open file', ...
                'Value', true);
            obj.warnViewOnlyCheck.Layout.Row = 3;
            obj.warnViewOnlyCheck.Layout.Column = [1 3];
        end

        function buildFileCard(obj, tab)
            g = uigridlayout(tab, [3 3]);
            g.Padding = [8 8 8 8];
            g.RowHeight = {24, 24, 24};
            g.ColumnWidth = {112, '1x', 36};
            g.RowSpacing = 6;
            g.ColumnSpacing = 6;

            L1 = uilabel(g, 'Text', 'Default name:', 'HorizontalAlignment', 'right');
            L1.Layout.Row = 1;
            L1.Layout.Column = 1;
            obj.defaultNameField = uieditfield(g, 'Editable', 'on');
            obj.defaultNameField.Layout.Row = 1;
            obj.defaultNameField.Layout.Column = 2;
            ep1 = uilabel(g, 'Text', '');
            ep1.Layout.Row = 1;
            ep1.Layout.Column = 3;
            L2 = uilabel(g, 'Text', 'Default location:', 'HorizontalAlignment', 'right');
            L2.Layout.Row = 2;
            L2.Layout.Column = 1;
            obj.defaultLocationField = uieditfield(g, 'Editable', 'on');
            obj.defaultLocationField.Layout.Row = 2;
            obj.defaultLocationField.Layout.Column = 2;
            obj.browseDefaultLocationButton = uibutton(g, 'Text', '...', 'Tooltip', 'Browse', ...
                'ButtonPushedFcn', @(~,~)obj.browseDefaultLocation());
            obj.browseDefaultLocationButton.Layout.Row = 2;
            obj.browseDefaultLocationButton.Layout.Column = 3;
            L3 = uilabel(g, 'Text', 'Cleanup function:', 'HorizontalAlignment', 'right');
            L3.Layout.Row = 3;
            L3.Layout.Column = 1;
            obj.cleanupFunctionField = uieditfield(g, 'Editable', 'on');
            obj.cleanupFunctionField.Layout.Row = 3;
            obj.cleanupFunctionField.Layout.Column = [2 3];
        end

        function buildSearchCard(obj, tab)
            outer = uigridlayout(tab, [2 1]);
            outer.Padding = [8 8 8 8];
            outer.RowHeight = {'1x', 28};
            outer.RowSpacing = 8;

            row = uigridlayout(outer, [1 2]);
            row.Layout.Row = 1;
            row.Layout.Column = 1;
            row.ColumnWidth = {'1x', 88};
            row.Padding = [0 0 0 0];

            obj.searchPathList = uilistbox(row, 'Multiselect', 'off', 'Items', {});
            obj.searchPathList.Layout.Row = 1;
            obj.searchPathList.Layout.Column = 1;

            btns = uigridlayout(row, [3 1]);
            btns.Layout.Row = 1;
            btns.Layout.Column = 2;
            btns.RowHeight = {28, 28, '1x'};
            btns.Padding = [0 0 0 0];
            obj.addPathButton = uibutton(btns, 'Text', 'Add...', 'ButtonPushedFcn', @(~,~)obj.addSearchPath());
            obj.addPathButton.Layout.Row = 1;
            obj.addPathButton.Layout.Column = 1;
            obj.removePathButton = uibutton(btns, 'Text', 'Remove', 'ButtonPushedFcn', @(~,~)obj.removeSearchPath());
            obj.removePathButton.Layout.Row = 2;
            obj.removePathButton.Layout.Column = 1;

            ex = uigridlayout(outer, [1 3]);
            ex.Layout.Row = 2;
            ex.Layout.Column = 1;
            ex.ColumnWidth = {52, '1x', 72};
            ex.Padding = [0 0 0 0];
            Lex = uilabel(ex, 'Text', 'Exclude:', 'HorizontalAlignment', 'right');
            Lex.Layout.Row = 1;
            Lex.Layout.Column = 1;
            obj.excludeField = uieditfield(ex, 'Editable', 'on');
            obj.excludeField.Layout.Row = 1;
            obj.excludeField.Layout.Column = 2;
            obj.excludeHelpButton = uibutton(ex, 'Text', 'Help', 'ButtonPushedFcn', @(~,~)obj.showExcludeHelp());
            obj.excludeHelpButton.Layout.Row = 1;
            obj.excludeHelpButton.Layout.Column = 3;
        end

        function buildLoggingCard(obj, tab)
            g = uigridlayout(tab, [2 3]);
            g.Padding = [8 8 8 8];
            g.RowHeight = {24, 24};
            g.ColumnWidth = {120, '1x', 36};
            g.RowSpacing = 6;
            g.ColumnSpacing = 6;

            Lc = uilabel(g, 'Text', 'Configuration file:', 'HorizontalAlignment', 'right');
            Lc.Layout.Row = 1;
            Lc.Layout.Column = 1;
            obj.loggingConfigField = uieditfield(g, 'Editable', 'on');
            obj.loggingConfigField.Layout.Row = 1;
            obj.loggingConfigField.Layout.Column = 2;
            obj.browseLoggingConfigButton = uibutton(g, 'Text', '...', 'Tooltip', 'Browse', ...
                'ButtonPushedFcn', @(~,~)obj.browseLoggingConfig());
            obj.browseLoggingConfigButton.Layout.Row = 1;
            obj.browseLoggingConfigButton.Layout.Column = 3;
            Ld = uilabel(g, 'Text', 'Log directory:', 'HorizontalAlignment', 'right');
            Ld.Layout.Row = 2;
            Ld.Layout.Column = 1;
            obj.loggingDirField = uieditfield(g, 'Editable', 'on');
            obj.loggingDirField.Layout.Row = 2;
            obj.loggingDirField.Layout.Column = 2;
            obj.browseLoggingDirButton = uibutton(g, 'Text', '...', 'Tooltip', 'Browse', ...
                'ButtonPushedFcn', @(~,~)obj.browseLoggingDir());
            obj.browseLoggingDirButton.Layout.Row = 2;
            obj.browseLoggingDirButton.Layout.Column = 3;
        end

        function buildStreamingCard(obj, tab)
            g = uigridlayout(tab, [4 3]);
            g.Padding = [8 8 8 8];
            g.RowHeight = {24, 24, 24, '1x'};
            g.ColumnWidth = {160, 80, '1x'};
            g.RowSpacing = 6;
            g.ColumnSpacing = 6;

            obj.streamingEnabledCheck = uicheckbox(g, ...
                'Text', 'Enable streaming mode', ...
                'Value', false);
            obj.streamingEnabledCheck.Layout.Row = 1;
            obj.streamingEnabledCheck.Layout.Column = [1 3];

            Lt = uilabel(g, 'Text', 'Threshold (seconds):', 'HorizontalAlignment', 'right');
            Lt.Layout.Row = 2; Lt.Layout.Column = 1;
            obj.streamingThresholdField = uieditfield(g, 'text', 'Value', '5');
            obj.streamingThresholdField.Layout.Row = 2;
            obj.streamingThresholdField.Layout.Column = [2 3];

            Lc = uilabel(g, 'Text', 'Display window:', 'HorizontalAlignment', 'right');
            Lc.Layout.Row = 3; Lc.Layout.Column = 1;
            obj.streamingMaxChunksField = uieditfield(g, 'text', 'Value', '10', ...
                'ValueChangedFcn', @(~,~) obj.updateStreamingTimeLabel());
            obj.streamingMaxChunksField.Layout.Row = 3;
            obj.streamingMaxChunksField.Layout.Column = 2;
            obj.streamingTimeLabel = uilabel(g, 'Text', '', 'FontSize', 11, ...
                'FontColor', [0.4 0.4 0.4]);
            obj.streamingTimeLabel.Layout.Row = 3;
            obj.streamingTimeLabel.Layout.Column = 3;
            obj.updateStreamingTimeLabel();

            helpLbl = uilabel(g, ...
                'Text', ['When enabled, epochs longer than the threshold switch to ' ...
                         'ring-buffer mode. Only the most recent window of data ' ...
                         'is kept in RAM; earlier data is streamed directly to the HDF5 file. ' ...
                         'This prevents memory growth during long recordings.'], ...
                'WordWrap', 'on', 'FontSize', 11, 'FontColor', [0.4 0.4 0.4]);
            helpLbl.Layout.Row = 4;
            helpLbl.Layout.Column = [1 3];
        end

        function updateStreamingTimeLabel(obj)
            try
                nChunks = str2double(obj.streamingMaxChunksField.Value);
                if isnan(nChunks) || nChunks < 1
                    nChunks = 10;
                end
                approxSec = nChunks * 0.25;  % ~250ms per chunk (ProcessInterval)
                obj.streamingTimeLabel.Text = sprintf('chunks (~%.1f sec window)', approxSec);
            catch
                obj.streamingTimeLabel.Text = 'chunks';
            end
        end

        function populateFromOptions(obj)
            o = obj.options;

            obj.startupFileField.Value = symphonyui.ui.SymphonyOptionsDialog.toChar(o.startupFile);
            obj.cleanupFileField.Value = symphonyui.ui.SymphonyOptionsDialog.toChar(o.cleanupFile);
            obj.warnViewOnlyCheck.Value = logical(o.warnOnViewOnlyWithOpenFile);

            obj.defaultNameField.Value = symphonyui.ui.SymphonyOptionsDialog.toChar(o.fileDefaultName);
            obj.defaultLocationField.Value = symphonyui.ui.SymphonyOptionsDialog.toChar(o.fileDefaultLocation);
            obj.cleanupFunctionField.Value = symphonyui.ui.SymphonyOptionsDialog.funcToDisplay(o.fileCleanupFunction);

            obj.searchPathList.Items = {};
            sp = o.searchPath;
            if isa(sp, 'function_handle')
                sp = sp();
            end
            sp = char(sp);
            if ~isempty(sp)
                parts = strsplit(sp, ';');
                obj.searchPathList.Items = cellstr(parts(:));
            end
            obj.excludeField.Value = symphonyui.ui.SymphonyOptionsDialog.toChar(o.searchPathExclude);

            obj.loggingConfigField.Value = symphonyui.ui.SymphonyOptionsDialog.toChar(o.loggingConfigurationFile);
            obj.loggingDirField.Value = symphonyui.ui.SymphonyOptionsDialog.toChar(o.loggingLogDirectory);

            obj.streamingEnabledCheck.Value = logical(o.streamingEnabled);
            obj.streamingThresholdField.Value = num2str(o.streamingThreshold);
            obj.streamingMaxChunksField.Value = num2str(o.streamingMaxDisplayChunks);
            obj.updateStreamingTimeLabel();
        end

        function browseStartup(obj)
            [f, p] = uigetfile('*.m', 'Select Startup File');
            if isnumeric(f) && f == 0
                return;
            end
            obj.startupFileField.Value = fullfile(p, f);
        end

        function browseCleanup(obj)
            [f, p] = uigetfile('*.m', 'Select Cleanup File');
            if isnumeric(f) && f == 0
                return;
            end
            obj.cleanupFileField.Value = fullfile(p, f);
        end

        function browseDefaultLocation(obj)
            d = uigetdir(obj.defaultLocationField.Value, 'Select Default Location');
            if isnumeric(d) && d == 0
                return;
            end
            obj.defaultLocationField.Value = char(d);
        end

        function browseLoggingConfig(obj)
            [f, p] = uigetfile('*.xml', 'Select Configuration File');
            if isnumeric(f) && f == 0
                return;
            end
            obj.loggingConfigField.Value = fullfile(p, f);
        end

        function browseLoggingDir(obj)
            d = uigetdir(obj.loggingDirField.Value, 'Select Log Directory');
            if isnumeric(d) && d == 0
                return;
            end
            obj.loggingDirField.Value = char(d);
        end

        function addSearchPath(obj)
            d = uigetdir(pwd, 'Select Path');
            if isnumeric(d) && d == 0
                return;
            end
            d = char(d);
            [~, name] = fileparts(d);
            if strncmp(name, '+', 1)
                uialert(obj.fig, [ ...
                    'Cannot add package directories (directories starting with +) to the search path. ' ...
                    'Add the root directory containing the package instead.'], ...
                    'Search Path', 'Icon', 'warning');
                return;
            end
            items = obj.searchPathList.Items;
            if isstring(items)
                items = cellstr(items(:));
            end
            if isempty(items)
                items = {d};
            else
                items = [items(:)', {d}];
            end
            obj.searchPathList.Items = items;
        end

        function removeSearchPath(obj)
            items = obj.searchPathList.Items;
            if isempty(items)
                return;
            end
            if isstring(items)
                items = cellstr(items(:));
            end
            val = obj.searchPathList.Value;
            if isempty(val)
                return;
            end
            if isnumeric(val)
                idx = val;
            else
                idx = find(strcmp(items(:), char(string(val))), 1);
            end
            if isempty(idx) || idx < 1 || idx > numel(items)
                return;
            end
            items(idx) = [];
            obj.searchPathList.Items = items;
        end

        function showExcludeHelp(obj)
            msg = sprintf([ ...
                'Exclude is a regular expression or expressions (separated by semicolons) that is evaluated against ' ...
                'the full name (e.g. my.package.ClassName) of each class in the Symphony search path. If the expression ' ...
                'results in a match, the class is excluded and will not be display in Symphony popup menus.\n\n' ...
                'Examples:\n' ...
                'Pulse\t\t - Excludes all classes with "Pulse" in its full class name.\n' ...
                'protocols.bill\t\t - Excludes all classes with "protocols.bill" in its full class name.\n' ...
                'Pulse; protocols.bill\t - Excludes all classes with "Pulse" or "protocols.bill" in its full class name.\n' ...
                'protocols.bill.\\w*Pulse\t - Excludes all classes with "protocols.bill." followed by "Pulse" in its full class name.']);
            uialert(obj.fig, msg, 'Exclude', 'Icon', 'info');
        end

        function onSave(obj)
            o = obj.options;
            try
                startupFile = symphonyui.ui.SymphonyOptionsDialog.parseField(obj.startupFileField.Value);
                cleanupFile = symphonyui.ui.SymphonyOptionsDialog.parseField(obj.cleanupFileField.Value);
                warnOnViewOnlyWithOpenFile = obj.warnViewOnlyCheck.Value;
                fileDefaultName = symphonyui.ui.SymphonyOptionsDialog.parseField(obj.defaultNameField.Value);
                fileDefaultLocation = symphonyui.ui.SymphonyOptionsDialog.parseField(obj.defaultLocationField.Value);
                fileCleanupFunction = str2func(obj.cleanupFunctionField.Value);
                items = obj.searchPathList.Items;
                if isempty(items)
                    searchPath = '';
                else
                    searchPath = strjoin(cellstr(items(:)), ';');
                end
                searchPathExclude = char(string(obj.excludeField.Value));
                loggingConfigurationFile = symphonyui.ui.SymphonyOptionsDialog.parseField(obj.loggingConfigField.Value);
                loggingLogDirectory = symphonyui.ui.SymphonyOptionsDialog.parseField(obj.loggingDirField.Value);
            catch ex
                uialert(obj.fig, ex.message, 'Options', 'Icon', 'error');
                return;
            end

            if ~isequal(startupFile, o.startupFile), o.startupFile = startupFile; end
            if ~isequal(cleanupFile, o.cleanupFile), o.cleanupFile = cleanupFile; end
            if ~isequal(warnOnViewOnlyWithOpenFile, o.warnOnViewOnlyWithOpenFile)
                o.warnOnViewOnlyWithOpenFile = warnOnViewOnlyWithOpenFile;
            end
            if ~isequal(fileDefaultName, o.fileDefaultName), o.fileDefaultName = fileDefaultName; end
            if ~isequal(fileDefaultLocation, o.fileDefaultLocation), o.fileDefaultLocation = fileDefaultLocation; end
            if ~isequal(fileCleanupFunction, o.fileCleanupFunction), o.fileCleanupFunction = fileCleanupFunction; end
            curSp = o.searchPath;
            if isa(curSp, 'function_handle')
                curSp = curSp();
            end
            curSp = char(string(curSp));
            if ~strcmp(searchPath, curSp)
                o.searchPath = searchPath;
            end
            if ~strcmp(searchPathExclude, char(string(o.searchPathExclude)))
                o.searchPathExclude = searchPathExclude;
            end
            if ~isequal(loggingConfigurationFile, o.loggingConfigurationFile)
                o.loggingConfigurationFile = loggingConfigurationFile;
            end
            if ~isequal(loggingLogDirectory, o.loggingLogDirectory), o.loggingLogDirectory = loggingLogDirectory; end

            % Streaming
            streamingEnabled = logical(obj.streamingEnabledCheck.Value);
            streamingThreshold = str2double(obj.streamingThresholdField.Value);
            streamingMaxChunks = str2double(obj.streamingMaxChunksField.Value);
            if isnan(streamingThreshold) || streamingThreshold <= 0
                streamingThreshold = 5;
            end
            if isnan(streamingMaxChunks) || streamingMaxChunks < 1
                streamingMaxChunks = 10;
            end
            o.streamingEnabled = streamingEnabled;
            o.streamingThreshold = streamingThreshold;
            o.streamingMaxDisplayChunks = round(streamingMaxChunks);

            try
                o.save();
            catch ex
                uialert(obj.fig, ex.message, 'Options', 'Icon', 'error');
                return;
            end

            pf = obj.parentFigure;
            obj.closeDialog();
            if ~isempty(pf) && isvalid(pf)
                uialert(pf, 'Options saved. Most values will not apply until the app is restarted.', ...
                    'Options Saved', 'Icon', 'info');
            end
        end

        function onDefault(obj)
            answer = uiconfirm(obj.fig, 'Are you sure you want to reset options to default values?', ...
                'Reset Options', 'Options', {'Cancel', 'Reset'});
            if isempty(answer) || ~strcmp(answer, 'Reset')
                return;
            end
            try
                obj.options.reset();
            catch ex
                uialert(obj.fig, ex.message, 'Options', 'Icon', 'error');
                return;
            end
            obj.populateFromOptions();
        end

        function onCancel(obj)
            obj.closeDialog();
        end

        function onKeyPress(obj, event)
            switch event.Key
                case 'return'
                    obj.onSave();
                case 'escape'
                    obj.onCancel();
            end
        end

        function onCloseRequest(obj)
            obj.closeDialog();
        end

        function closeDialog(obj)
            try
                if ~isempty(obj.fig) && isvalid(obj.fig)
                    % Save position for next time
                    try
                        setpref('SymphonyUI', 'OptionsDialogPosition', obj.fig.Position);
                    catch
                    end
                    delete(obj.fig);
                end
            catch
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
        function s = toChar(v)
            if isa(v, 'function_handle')
                % Show the function definition so the user can edit it.
                % The handle is evaluated later when actually needed
                % (e.g. when creating a new file).
                s = ['@' func2str(v)];
                % func2str on anonymous functions already includes '@',
                % so avoid doubling it.
                if startsWith(s, '@@')
                    s = s(2:end);
                end
                return;
            end
            s = char(string(v));
        end

        function s = funcToDisplay(fh)
            if isa(fh, 'function_handle')
                s = func2str(fh);
            else
                s = char(string(fh));
            end
        end

        function out = parseField(s)
            s = char(string(s));
            if isempty(strtrim(s))
                out = '';
                return;
            end
            if s(1) == '@'
                out = str2func(s);
            else
                out = s;
            end
        end
    end
end
