classdef InitializeRigDialog < handle
    %INITIALIZERIGDIALOG  Configure → Initialize Rig (uifigure modal dialog).
    %   Scans Options search paths for symphonyui.core.descriptions.RigDescription
    %   subclasses and initializes the selected rig via the C# AcquisitionHost.

    properties (Access = private)
        fig matlab.ui.Figure
        parentFigure
        host  % IAcquisitionHost (.NET)
        result  % true if rig initialized, [] if cancelled

        rigDropdown matlab.ui.control.DropDown
        initButton matlab.ui.control.Button
        cancelButton matlab.ui.control.Button

        rigIds  % cell array of rig class name strings (parallel to dropdown items)
        searchPaths  % cell array of directories to scan
    end

    methods (Static)
        function result = showBlocking(parentFigure, host, searchPaths)
            %SHOWBLOCKING  Open modal Initialize Rig dialog and block until done.
            %   searchPaths: cell array of directories to scan for +rigs packages.
            if nargin < 3
                searchPaths = {};
            end
            dlg = symphonyui.ui.InitializeRigDialog(parentFigure, host, searchPaths);
            dlg.fig.Visible = 'on';
            uiwait(dlg.fig);
            result = dlg.result;
        end
    end

    methods (Access = private)
        function obj = InitializeRigDialog(parentFigure, host, searchPaths)
            obj.parentFigure = parentFigure;
            obj.host = host;
            obj.searchPaths = searchPaths;
            obj.result = [];
            obj.rigIds = {};
            obj.buildUi();
            obj.populate();
        end

        function buildUi(obj)
            w = 340;
            h = 120;
            pos = obj.centerOnParent(w, h);

            obj.fig = uifigure( ...
                'Name', 'Initialize Rig', ...
                'Position', pos, ...
                'WindowStyle', 'modal', ...
                'Color', [0.94 0.94 0.94], ...
                'Resize', 'off', ...
                'CloseRequestFcn', @(~,~)obj.onCancel(), ...
                'KeyPressFcn', @(~,e)obj.onKeyPress(e), ...
                'WindowKeyPressFcn', @(~,e)obj.onKeyPress(e));

            main = uigridlayout(obj.fig, [2 2]);
            main.RowHeight = {28, 40};
            main.ColumnWidth = {90, '1x'};
            main.Padding = [12 12 12 12];
            main.RowSpacing = 10;
            main.ColumnSpacing = 8;

            % Row 1: Rig dropdown
            lbl = uilabel(main, 'Text', 'Description:', 'HorizontalAlignment', 'right');
            lbl.Layout.Row = 1;
            lbl.Layout.Column = 1;
            obj.rigDropdown = uidropdown(main, 'Items', {'(loading...)'});
            obj.rigDropdown.Layout.Row = 1;
            obj.rigDropdown.Layout.Column = 2;

            % Row 2: Buttons
            btnGrid = uigridlayout(main, [1 3]);
            btnGrid.Layout.Row = 2;
            btnGrid.Layout.Column = [1 2];
            btnGrid.ColumnWidth = {'1x', 80, 80};
            btnGrid.Padding = [0 0 0 0];

            uilabel(btnGrid, 'Text','');  % spacer
            obj.initButton = uibutton(btnGrid, 'Text', 'Initialize', ...
                'ButtonPushedFcn', @(~,~)obj.onInitialize());
            obj.cancelButton = uibutton(btnGrid, 'Text', 'Cancel', ...
                'ButtonPushedFcn', @(~,~)obj.onCancel());

            symphonyui.ui.DialogUtil.setKeyPressFcnRecursive(obj.fig, @(~,e)obj.onKeyPress(e));
        end

        function populate(obj)
            try
                rigs = symphonyui.ui.ProtocolScanner.discoverRigs(obj.searchPaths);
                n = numel(rigs);
                if n == 0
                    obj.rigDropdown.Items = {'(no rigs available)'};
                    obj.rigIds = {};
                    obj.initButton.Enable = 'off';
                    return;
                end
                labels = cell(1, n);
                ids = cell(1, n);
                for i = 1:n
                    labels{i} = rigs(i).displayName;
                    ids{i} = rigs(i).id;
                end
                obj.rigDropdown.Items = labels;
                obj.rigIds = ids;
            catch ex
                obj.rigDropdown.Items = {'(error loading rigs)'};
                obj.rigIds = {};
                obj.initButton.Enable = 'off';
                uialert(obj.fig, ex.message, 'Initialize Rig');
            end
        end

        function onInitialize(obj)
            if isempty(obj.rigIds)
                return;
            end
            idx = find(strcmp(obj.rigDropdown.Items, obj.rigDropdown.Value), 1);
            if isempty(idx) || idx < 1 || idx > numel(obj.rigIds)
                return;
            end
            rigId = obj.rigIds{idx};
            try
                % Construct the RigDescription and wrap it in a Rig
                ctorFcn = str2func(rigId);
                description = ctorFcn();
                rig = symphonyui.core.Rig(description);

                % Notify the C# host if available. Skipped on macOS
                % because .GetAwaiter().GetResult() schedules Task
                % continuations on MATLAB's timer thread that crash
                % via the broken .NET Core bridge. The host call is
                % only needed for hardware acquisition; simulation-only
                % testing on Mac doesn't require it.
                if ispc
                    try
                        obj.host.InitializeRigAsync(rigId).GetAwaiter().GetResult();
                    catch
                        % Host may not support this rig — MATLAB side takes precedence
                    end
                end

                obj.result = rig;
                obj.closeDialog();
            catch ex
                % Dump full stack trace to command window for debugging
                fprintf(2, '\n=== Initialize Rig Error ===\n');
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
                fprintf(2, '============================\n\n');
                uialert(obj.fig, ex.message, 'Initialize Rig Error');
            end
        end

        function onCancel(obj)
            obj.result = [];
            obj.closeDialog();
        end

        function onKeyPress(obj, event)
            switch event.Key
                case 'return'
                    obj.onInitialize();
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
