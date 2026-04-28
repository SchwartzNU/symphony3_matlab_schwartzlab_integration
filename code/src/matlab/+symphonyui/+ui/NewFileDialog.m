classdef NewFileDialog < handle
    %NEWFILEDIALOG  File -> New (uifigure modal dialog).
    %   Collects file name, location, and experiment description, then creates
    %   the file via the C# AcquisitionHost. Scans search paths for
    %   ExperimentDescription subclasses to populate the Description dropdown.

    properties (Access = private)
        fig matlab.ui.Figure
        parentFigure
        host  % IAcquisitionHost (.NET)
        result  % true if file created, [] if cancelled
        searchPaths  % cell array of directories to scan

        nameField matlab.ui.control.EditField
        locationField matlab.ui.control.EditField
        browseButton matlab.ui.control.Button
        descriptionDropdown matlab.ui.control.DropDown
        okButton matlab.ui.control.Button
        cancelButton matlab.ui.control.Button

        experimentIds  % cell array of class names (parallel to dropdown items)
    end

    methods (Static)
        function result = showBlocking(parentFigure, host, searchPaths)
            %SHOWBLOCKING  Open modal New File dialog and block until Ok or Cancel.
            %   searchPaths: cell array of directories to scan for +experiments.
            if nargin < 3
                searchPaths = {};
            end
            dlg = symphonyui.ui.NewFileDialog(parentFigure, host, searchPaths);
            dlg.fig.Visible = 'on';
            uiwait(dlg.fig);
            result = dlg.result;
        end
    end

    methods (Access = private)
        function obj = NewFileDialog(parentFigure, host, searchPaths)
            obj.parentFigure = parentFigure;
            obj.host = host;
            obj.searchPaths = searchPaths;
            obj.result = [];
            obj.experimentIds = {};
            obj.buildUi();
            obj.populate();
        end

        function buildUi(obj)
            w = 500;
            h = 180;
            pos = obj.centerOnParent(w, h);

            obj.fig = uifigure( ...
                'Name', 'New File', ...
                'Position', pos, ...
                'WindowStyle', 'modal', ...
                'Color', [0.94 0.94 0.94], ...
                'Resize', 'off', ...
                'CloseRequestFcn', @(~,~)obj.onCancel(), ...
                'KeyPressFcn', @(~,e)obj.onKeyPress(e), ...
                'WindowKeyPressFcn', @(~,e)obj.onKeyPress(e));

            main = uigridlayout(obj.fig, [4 3]);
            main.RowHeight = {28, 28, 28, 40};
            main.ColumnWidth = {90, '1x', 80};
            main.Padding = [12 12 12 12];
            main.RowSpacing = 8;
            main.ColumnSpacing = 8;

            % Row 1: Name
            lbl1 = uilabel(main, 'Text', 'Name:', 'HorizontalAlignment', 'right');
            lbl1.Layout.Row = 1; lbl1.Layout.Column = 1;
            obj.nameField = uieditfield(main, 'text');
            obj.nameField.Layout.Row = 1; obj.nameField.Layout.Column = [2 3];

            % Row 2: Location
            lbl2 = uilabel(main, 'Text', 'Location:', 'HorizontalAlignment', 'right');
            lbl2.Layout.Row = 2; lbl2.Layout.Column = 1;
            obj.locationField = uieditfield(main, 'text');
            obj.locationField.Layout.Row = 2; obj.locationField.Layout.Column = 2;
            obj.browseButton = uibutton(main, 'Text', 'Browse...', ...
                'ButtonPushedFcn', @(~,~)obj.onBrowse());
            obj.browseButton.Layout.Row = 2; obj.browseButton.Layout.Column = 3;

            % Row 3: Description
            lbl3 = uilabel(main, 'Text', 'Description:', 'HorizontalAlignment', 'right');
            lbl3.Layout.Row = 3; lbl3.Layout.Column = 1;
            obj.descriptionDropdown = uidropdown(main, ...
                'Items', {'(loading...)'});
            obj.descriptionDropdown.Layout.Row = 3; obj.descriptionDropdown.Layout.Column = [2 3];

            % Row 4: Buttons
            btnGrid = uigridlayout(main, [1 3]);
            btnGrid.Layout.Row = 4;
            btnGrid.Layout.Column = [1 3];
            btnGrid.ColumnWidth = {'1x', 80, 80};
            btnGrid.Padding = [0 0 0 0];

            uilabel(btnGrid, "Text", '');  % spacer
            obj.okButton = uibutton(btnGrid, 'Text', 'Save', ...
                'ButtonPushedFcn', @(~,~)obj.onOk());
            obj.cancelButton = uibutton(btnGrid, 'Text', 'Cancel', ...
                'ButtonPushedFcn', @(~,~)obj.onCancel());

            symphonyui.ui.DialogUtil.setKeyPressFcnRecursive(obj.fig, @(~,e)obj.onKeyPress(e));
        end

        function populate(obj)
            % Default name from Options (may be a function handle)
            defaultName = [datestr(now, 'yyyy-mm-dd') '.h5']; %#ok<TNOW1,DATST>
            defaultLoc = pwd;
            try
                options = symphonyui.app.Options.getDefault();
                % File default name
                fn = options.fileDefaultName;
                if isa(fn, 'function_handle')
                    try
                        fn = fn();
                    catch
                        % The stored function handle may use datestr('now',...)
                        % which fails in newer MATLAB. Try replacing 'now'
                        % with the now function result in a fresh anonymous fcn.
                        fstr = func2str(fn);
                        fstr = strrep(fstr, "datestr('now'", 'datestr(now');
                        fstr = strrep(fstr, 'datestr("now"', 'datestr(now');
                        try
                            fn = str2func(fstr);
                            fn = fn();
                        catch
                            fn = '';
                        end
                    end
                end
                fn = char(fn);
                if ~isempty(fn)
                    % Ensure .h5 extension
                    [~, ~, ext] = fileparts(fn);
                    if isempty(ext)
                        fn = [fn '.h5'];
                    end
                    defaultName = fn;
                end
                % File default location
                loc = options.fileDefaultLocation;
                if isa(loc, 'function_handle')
                    loc = loc();
                end
                loc = char(loc);
                if ~isempty(loc) && isfolder(loc)
                    defaultLoc = loc;
                end
            catch
            end
            obj.nameField.Value = defaultName;
            obj.locationField.Value = defaultLoc;

            % Scan search paths for ExperimentDescription subclasses
            try
                experiments = symphonyui.ui.ProtocolScanner.discoverExperiments(obj.searchPaths);
            catch ex
                fprintf(2, 'NewFileDialog: experiment discovery failed: %s\n', ex.message);
                experiments = struct('id', {}, 'displayName', {});
            end

            n = numel(experiments);
            if n == 0
                obj.descriptionDropdown.Items = {'(None)'};
                obj.experimentIds = {''};
            else
                labels = cell(1, n);
                ids = cell(1, n);
                for i = 1:n
                    labels{i} = experiments(i).displayName;
                    ids{i} = experiments(i).id;
                end
                obj.descriptionDropdown.Items = labels;
                obj.experimentIds = ids;
            end
        end

        function onBrowse(obj)
            folder = uigetdir(obj.locationField.Value, 'Select File Location');
            if ~isequal(folder, 0)
                obj.locationField.Value = folder;
            end
        end

        function onOk(obj)
            name = strtrim(obj.nameField.Value);
            if isempty(name)
                uialert(obj.fig, 'Please enter a file name.', 'New File');
                return;
            end
            % Ensure .h5 extension
            [~, baseName, ext] = fileparts(name);
            if isempty(ext)
                ext = '.h5';
                name = [baseName ext];
            end

            location = strtrim(obj.locationField.Value);
            if isempty(location) || ~isfolder(location)
                uialert(obj.fig, 'Please select a valid location.', 'New File');
                return;
            end

            % Get the selected experiment description class name
            idx = find(strcmp(obj.descriptionDropdown.Items, obj.descriptionDropdown.Value), 1);
            if ~isempty(idx) && idx >= 1 && idx <= numel(obj.experimentIds)
                description = obj.experimentIds{idx};
            else
                description = '';
            end

            % Check if file already exists
            fullPath = fullfile(location, name);
            if isfile(fullPath)
                answer = uiconfirm(obj.fig, ...
                    sprintf('File "%s" already exists. Overwrite?', name), ...
                    'New File', 'Options', {'Overwrite', 'Cancel'}, ...
                    'DefaultOption', 'Cancel');
                if ~strcmp(answer, 'Overwrite')
                    return;
                end
                delete(fullPath);
            end

            try
                req = Symphony.Acquisition.Contracts.NewFileRequest(name, location, description);
                obj.host.NewFileAsync(req).GetAwaiter().GetResult();
                obj.result = struct('success', true, 'experimentDescriptionId', description);
                obj.closeDialog();
            catch ex
                fprintf(2, '\n=== New File Error ===\n%s\n', getReport(ex, 'extended'));
                uialert(obj.fig, ex.message, 'New File Error');
            end
        end

        function onCancel(obj)
            obj.result = [];
            obj.closeDialog();
        end

        function onKeyPress(obj, event)
            switch event.Key
                case 'return'
                    obj.onOk();
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
