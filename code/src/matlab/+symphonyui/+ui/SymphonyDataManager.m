classdef SymphonyDataManager < handle
    %SYMPHONYDATAMANAGER  Data Manager uifigure modeled on legacy DataManagerView.m
    %   Layout: top-level menu actions, entity tree (left), detail cards + tabs (right).
    %   Requires MATLAB R2022b+ (uitree/uitreenode NodeData, uimenu on uifigure).

    properties (Access = private)
        host
        parentFigure matlab.ui.Figure
        onAfterHostMutation
        onConfigureDevices
        fig
        tree matlab.ui.container.Tree
        % Stacked detail cards (same layout cell; normalized positions)
        cardStack matlab.ui.container.Panel
        cardEmpty matlab.ui.container.Panel
        cardExperiment matlab.ui.container.Panel
        cardSource matlab.ui.container.Panel
        cardEpochGroup matlab.ui.container.Panel
        cardEpochBlock matlab.ui.container.Panel
        cardEpoch matlab.ui.container.Panel
        % Experiment
        expPurposeField matlab.ui.control.EditField
        expStartLabel matlab.ui.control.Label
        expEndLabel matlab.ui.control.Label
        % Source
        srcLabelField matlab.ui.control.EditField
        % Epoch group
        grpLabelField matlab.ui.control.EditField
        grpSourceDropDown matlab.ui.control.DropDown
        grpStartLabel matlab.ui.control.Label
        grpEndLabel matlab.ui.control.Label
        % Epoch block / epoch (read-only summary)
        blkProtocolLabel matlab.ui.control.Label
        blkTimesLabel matlab.ui.control.Label
        % Epoch waveform preview (HDF responses / stimuli)
        epochAxes
        epochResponseDropDown matlab.ui.control.DropDown
        lastEpochPreview % cached .NET PreviewSpecDto for replot when device selection changes
        % Tabs (Properties / Keywords / Notes / Parameters)
        annoTabGroup matlab.ui.container.TabGroup
        propTable matlab.ui.control.Table
        propDynamicGrid  % uigridlayout for experiment description (dropdowns)
        propDynamicControls cell = {}  % dynamic controls in the properties tab
        propTabGrid  % outer grid in Properties tab
        grpDescGrid  % uigridlayout for epoch group description properties
        keywordsTable matlab.ui.control.Table
        notesTable matlab.ui.control.Table
        parametersTable matlab.ui.control.Table
        footerLabel matlab.ui.control.Label
        % Menu items (for enable/disable)
        menuAddSource
        menuBeginEpochGroup
        menuEndEpochGroup
        % Splitters for resizable panels
        hSplitter   % horizontal: tree (left) | right
        vSplitter   % vertical: detail cards (top) | tabs (bottom)
        % Last loaded state for dropdowns
        lastDm
        currentSelection struct = struct('kind', 'none', 'id', '')
        % Experiment description (MATLAB side)
        experimentDescriptionId char = ''
        experimentDescription  % cached ExperimentDescription instance
        expGrid  % uigridlayout inside cardExperiment
        expDescControls cell = {}  % {label, control} pairs for description properties
        % Right-click context menus are now created per-node (see make*ContextMenu).
        % These properties are unused but kept for compatibility.
        cmEpochGroup
        cmEpochBlock
        cmEpoch
        cmSource
        % When true, blocks all HDF5 reads (tree refresh, property display,
        % epoch plotting) to prevent concurrent access with C# writes.
        acquisitionMode logical = false
    end

    methods
        function obj = SymphonyDataManager(host, parentFigure, onAfterHostMutation, onConfigureDevices)
            if nargin < 3
                onAfterHostMutation = [];
            end
            if nargin < 4
                onConfigureDevices = [];
            end
            obj.host = host;
            obj.parentFigure = parentFigure;
            obj.onAfterHostMutation = onAfterHostMutation;
            obj.onConfigureDevices = onConfigureDevices;
        end

        function show(obj, action)
            if nargin < 2 || isempty(action)
                action = 'Opened';
            end
            if isempty(obj.fig) || ~isvalid(obj.fig)
                obj.buildFigure();
            end
            obj.fig.Name = sprintf('Data Manager — %s', action);
            % Restore experiment description from HDF5 if not already set
            if isempty(obj.experimentDescriptionId)
                obj.restoreExperimentDescriptionFromFile();
            end
            obj.refresh();
            obj.fig.Visible = 'on';
            % Force a layout pass now that the figure is visible and has
            % its final pixel dimensions.
            drawnow;
            try
                cb = obj.fig.SizeChangedFcn;
                if isa(cb, 'function_handle')
                    cb(obj.fig, []);
                end
            catch
            end
        end

        function setExperimentDescriptionId(obj, descId)
            %SETEXPERIMENTDESCRIPTIONID  Store the experiment description class name
            %   so Properties can be populated from the MATLAB description object.
            %   Also persists the ID to the HDF5 file for retrieval on reopen.
            obj.experimentDescriptionId = descId;
            obj.experimentDescription = [];

            % Remove previous dynamic description controls
            for k = 1:numel(obj.expDescControls)
                try delete(obj.expDescControls{k}); catch, end
            end
            obj.expDescControls = {};

            if ~isempty(descId)
                try
                    ctorFcn = str2func(descId);
                    obj.experimentDescription = ctorFcn();
                catch ex
                    fprintf(2, 'DataManager: could not instantiate experiment description "%s": %s\n', descId, ex.message);
                end
                % Note: the C# host now persists __experimentDescriptionId
                % to HDF5 during NewFileAsync, so no need to write it here.
            end

            % Add description property fields to the experiment card
            obj.rebuildExperimentDescriptionRows();
        end

        function restoreExperimentDescriptionFromFile(obj)
            %RESTOREEXPERIMENTDESCRIPTIONFROMFILE  Read the experiment description
            %   ID from the HDF5 file and rebuild the card fields, populating
            %   values from the file's stored properties.
            try
                cper = obj.host.GetPersistor();
                if isempty(cper)
                    return;
                end
                % Read the stored description ID
                props = cper.Experiment.Properties;
                descId = '';
                propMap = containers.Map();
                enumerator = props.GetEnumerator();
                while enumerator.MoveNext()
                    kv = enumerator.Current;
                    key = char(kv.Key);
                    val = kv.Value;
                    if strcmp(key, '__experimentDescriptionId')
                        descId = char(val);
                    else
                        % Store value for later populating the controls
                        try
                            if isa(val, 'System.String')
                                propMap(key) = char(val);
                            elseif isa(val, 'Symphony.Core.Measurement')
                                propMap(key) = double(val.Quantity);
                            else
                                propMap(key) = char(string(val));
                            end
                        catch
                            propMap(key) = char(string(val));
                        end
                    end
                end

                if isempty(descId)
                    return;
                end

                % Set the description ID (rebuilds the card rows)
                obj.experimentDescriptionId = descId;
                obj.experimentDescription = [];
                % Remove previous dynamic controls
                for k = 1:numel(obj.expDescControls)
                    try delete(obj.expDescControls{k}); catch, end
                end
                obj.expDescControls = {};
                try
                    ctorFcn = str2func(descId);
                    obj.experimentDescription = ctorFcn();
                catch ex
                    fprintf(2, 'DataManager: could not instantiate experiment description "%s": %s\n', descId, ex.message);
                    return;
                end

                % Override description default values with saved HDF5 values
                if ~isempty(obj.experimentDescription)
                    descriptors = obj.experimentDescription.getPropertyDescriptors();
                    for i = 1:numel(descriptors)
                        if propMap.isKey(descriptors(i).name)
                            descriptors(i).value = propMap(descriptors(i).name);
                        end
                    end
                end

                obj.rebuildExperimentDescriptionRows();
            catch ex
                fprintf(2, 'restoreExperimentDescriptionFromFile: %s\n', ex.message);
            end
        end

        function setAcquisitionMode(obj, tf)
            %SETACQUISITIONMODE  Block/unblock heavy HDF5 reads during acquisition.
            %   When tf=true, full tree refresh is blocked. Tree selection
            %   and entity property display are still allowed (safe with
            %   separate HDF5 libraries).
            obj.acquisitionMode = logical(tf);
            if ~tf && ~isempty(obj.fig) && isvalid(obj.fig)
                % Resuming — incremental refresh to show newly recorded data
                % (full rebuild is too slow for large files)
                try
                    obj.refresh(false);
                catch
                end
            end
        end

        function refresh(obj, fullRebuild)
            if isempty(obj.fig) || ~isvalid(obj.fig)
                return;
            end
            if nargin < 2, fullRebuild = true; end
            % During acquisition, block full rebuilds (heavy HDF5 enumeration)
            % but allow incremental updates using cached state.
            if obj.acquisitionMode && fullRebuild
                return;
            end

            % Throttle: minimum 300ms between refreshes to avoid rapid
            % HDF5 reads during burst state changes.
            persistent lastRefreshTic;
            if isempty(lastRefreshTic), lastRefreshTic = tic; end
            if toc(lastRefreshTic) < 0.3 && ~fullRebuild
                return;
            end
            lastRefreshTic = tic;

            try
                dm = obj.awaitTaskWithResult(obj.host.GetDataManagerStateAsync());
                obj.lastDm = dm;
                if fullRebuild
                    obj.populateTree(dm);
                    obj.populateEntityTabsEmpty();
                    obj.applySelectionAfterRefresh();
                else
                    obj.addNewTreeNodes(dm);
                end
            catch ex
                obj.showError(ex.message, 'Data Manager Error');
            end
            % Update menu enable/disable state
            obj.updateMenuState();

            % Restore focus to the Data Manager figure after operations
            % that may have shifted focus (e.g. listdlg, split, merge).
            try
                figure(obj.fig);
            catch
            end
        end

        function updateMenuState(obj)
            %UPDATEMENUSTATE  Enable/disable menus based on current state.
            try
                dm = obj.lastDm;
                if isempty(dm)
                    return;
                end

                % Add Source: always available (sources can be added at any time)
                % obj.menuAddSource.Enable = 'on';

                % Begin Epoch Group: only available if there are sources
                hasSources = false;
                try
                    n = SymphonyAppUtil.getNetCount(dm.Sources);
                    hasSources = n > 0;
                catch
                end
                if hasSources
                    obj.menuBeginEpochGroup.Enable = 'on';
                else
                    obj.menuBeginEpochGroup.Enable = 'off';
                end

                % End Epoch Group: only available if there is an open epoch group
                hasOpenEpochGroup = false;
                try
                    expState = obj.awaitTaskWithResult(obj.host.GetExperimentStateAsync());
                    hasOpenEpochGroup = logical(expState.HasEpochGroup);
                catch
                end
                if hasOpenEpochGroup
                    obj.menuEndEpochGroup.Enable = 'on';
                else
                    obj.menuEndEpochGroup.Enable = 'off';
                end
            catch
            end
        end

        function incrementalTreeUpdate(obj, dm)
            %INCREMENTALTREEUPDATE  Add new epochs/blocks without rebuilding the tree.
            %   Only adds nodes that don't already exist. Much faster than full rebuild.
            if isempty(obj.tree.Children)
                obj.populateTree(dm);
                return;
            end

            ic = @obj.iconIfAny;

            % Build set of existing node IDs
            existingIds = obj.collectAllNodeIds(obj.tree);

            % Check for new epoch blocks
            nBlocks = SymphonyAppUtil.getNetCount(dm.EpochBlocks);
            for i = 1:nBlocks
                b = SymphonyAppUtil.getNetItem(dm.EpochBlocks, i);
                bid = char(b.Id);
                if existingIds.isKey(bid)
                    continue;
                end
                % Find parent group node
                gid = char(b.EpochGroupId);
                if existingIds.isKey(gid)
                    parentNode = existingIds(gid);
                    bn = uitreenode(parentNode, 'Text', symphonyui.ui.SymphonyDataManager.blockLabel(b), 'Icon', ic('block.png'));
                    bn.NodeData = struct('kind', 'epoch_block', 'id', bid);
                    try bn.ContextMenu = obj.makeEpochBlockContextMenu(bn); catch, end
                    existingIds(bid) = bn;
                end
            end

            % Check for new epochs in expanded block nodes.
            % Epochs are no longer in the main DTO — fetch on-demand
            % per block to avoid O(n) HDF5 reads across all epochs.
            nBlocks = SymphonyAppUtil.getNetCount(dm.EpochBlocks);
            for i = 1:nBlocks
                b = SymphonyAppUtil.getNetItem(dm.EpochBlocks, i);
                bid = char(b.Id);
                if ~existingIds.isKey(bid), continue; end
                blockNode = existingIds(bid);
                % Only refresh blocks that already have children loaded
                if isempty(blockNode.Children), continue; end
                % Count existing epoch nodes
                existingEpochIds = containers.Map();
                for c = 1:numel(blockNode.Children)
                    cd = blockNode.Children(c).NodeData;
                    if isstruct(cd) && isfield(cd, 'id')
                        existingEpochIds(char(string(cd.id))) = true;
                    end
                end
                % Fetch current epochs for this block
                try
                    epochs = obj.awaitTaskWithResult(obj.host.GetEpochsForBlockAsync(bid));
                    nEpochs = SymphonyAppUtil.getNetCount(epochs);
                    for j = 1:nEpochs
                        ep = SymphonyAppUtil.getNetItem(epochs, j);
                        eid = char(ep.Id);
                        if existingEpochIds.isKey(eid), continue; end
                        en = uitreenode(blockNode, 'Text', char(ep.DisplayName), 'Icon', ic('epoch.png'));
                        en.NodeData = struct('kind', 'epoch', 'id', eid);
                        try en.ContextMenu = obj.makeEpochContextMenu(en); catch, end
                        existingIds(eid) = en;
                    end
                catch
                end
            end

            % Update current epoch group marker
            nGroups = SymphonyAppUtil.getNetCount(dm.EpochGroups);
            for i = 1:nGroups
                g = SymphonyAppUtil.getNetItem(dm.EpochGroups, i);
                gid = char(g.Id);
                if existingIds.isKey(gid)
                    node = existingIds(gid);
                    isCurrent = logical(g.IsCurrent);
                    src = obj.sourceLabelForId(dm, g.SourceId);
                    label = sprintf('%s (%s)', char(g.Label), src);
                    label = [label, symphonyui.ui.SymphonyDataManager.groupProtocolSuffix(dm, gid)];
                    if isCurrent, label = [label, ' *']; end
                    node.Text = label;
                end
            end
        end

        function idMap = collectAllNodeIds(~, tree)
            %COLLECTALLNODEIDS  Build a containers.Map from node ID → node handle.
            idMap = containers.Map('KeyType', 'char', 'ValueType', 'any');
            nodes = tree.Children;
            stack = {};
            for i = 1:numel(nodes)
                stack{end+1} = nodes(i); %#ok<AGROW>
            end
            while ~isempty(stack)
                n = stack{end};
                stack(end) = [];
                if ~isempty(n.NodeData) && isfield(n.NodeData, 'id') && ~isempty(n.NodeData.id)
                    idMap(n.NodeData.id) = n;
                end
                ch = n.Children;
                for i = 1:numel(ch)
                    stack{end+1} = ch(i); %#ok<AGROW>
                end
            end
        end

        function close(obj)
            try
                if ~isempty(obj.fig) && isvalid(obj.fig)
                    delete(obj.fig);
                end
            catch
            end
            obj.clearFigureHandles();
        end

        function onCloseRequest(obj)
            % Confirm before closing the Data Manager and the underlying file.
            try
                hasFile = obj.awaitTaskWithResult(obj.host.HasOpenFileAsync());
            catch
                hasFile = false;
            end
            if hasFile
                answer = uiconfirm(obj.fig, ...
                    'Close the current file and Data Manager?', ...
                    'Close File', ...
                    'Options', {'Close File', 'Cancel'}, ...
                    'DefaultOption', 'Cancel', ...
                    'Icon', 'question');
                if ~strcmp(answer, 'Close File')
                    return;
                end
                % Run the file cleanup function (if configured in Options)
                try
                    opts = symphonyui.app.Options.getDefault();
                    f = opts.fileCleanupFunction;
                    if ~isempty(f) && isa(f, 'function_handle')
                        fprintf('Running file cleanup function: %s\n', func2str(f));
                        try f(); catch, try f([]); catch, end, end
                    end
                catch
                end
                % Close the file via the host
                try
                    obj.awaitTask(obj.host.CloseFileAsync());
                catch ex
                    fprintf(2, 'Error closing file: %s\n', ex.message);
                end
                % Notify the main app so acquire controls update
                if ~isempty(obj.onAfterHostMutation) && isa(obj.onAfterHostMutation, 'function_handle')
                    try
                        obj.onAfterHostMutation();
                    catch
                    end
                end
            end
            symphonyui.ui.ViewSettings.savePosition(obj.fig, 'DataManager');
            obj.close();
        end
    end

    methods (Access = private)
        function onFigureResize(obj, mainPanel, footerPanel)
            w = obj.fig.Position(3);
            h = obj.fig.Position(4);
            mainPanel.Position = [0 24 w h - 24];
            footerPanel.Position = [0 0 w 24];
            % Programmatic Position changes don't fire SizeChangedFcn.
            % Manually trigger the hSplitter's layout via the callback.
            try
                cb = mainPanel.SizeChangedFcn;
                if isa(cb, 'function_handle')
                    cb(mainPanel, []);
                end
            catch
            end
        end

        function clearFigureHandles(obj)
            % Delete the figure — all children (tree, cards, etc.) are
            % destroyed automatically. Don't assign [] to typed properties
            % (e.g. matlab.ui.container.Tree) as that throws a type error.
            try
                if ~isempty(obj.fig) && isvalid(obj.fig)
                    delete(obj.fig);
                end
            catch
            end
            obj.srcLabelField = [];
            obj.grpLabelField = [];
            obj.grpSourceDropDown = [];
            obj.grpStartLabel = [];
            obj.grpEndLabel = [];
            obj.blkProtocolLabel = [];
            obj.blkTimesLabel = [];
            obj.epochAxes = [];
            obj.epochResponseDropDown = [];
            obj.lastEpochPreview = [];
            obj.annoTabGroup = [];
            obj.propTable = [];
            obj.keywordsTable = [];
            obj.notesTable = [];
            obj.parametersTable = [];
            obj.footerLabel = [];
            obj.cmEpochGroup = [];
            obj.cmEpochBlock = [];
            obj.cmEpoch = [];
            obj.cmSource = [];
        end

        function buildFigure(obj)
            obj.fig = uifigure( ...
                'Name', 'Data Manager', ...
                'Position', appbox.screenCenter(800,500), ...
                'Color', [0.94 0.94 0.94], ...
                'AutoResizeChildren', 'off', ...
                'CloseRequestFcn', @(~,~) obj.onCloseRequest(), ...
                'WindowKeyPressFcn', @(~, e) obj.onFigureKeyPress(e));   % fires whichever component has focus
            symphonyui.ui.ViewSettings.restorePosition(obj.fig, 'DataManager');

            % Menu bar grouped like Symphony 2's Data Manager (top-level
            % uimenus in a uifigure render as one crowded row otherwise).
            documentMenu = uimenu(obj.fig, 'Text', 'Document');
            obj.menuAddSource = uimenu(documentMenu, 'Text', 'Add Source...', ...
                'MenuSelectedFcn', @(~, ~)obj.addSource());
            obj.menuBeginEpochGroup = uimenu(documentMenu, 'Text', 'Begin Epoch Group...   Ctrl+B', ...
                'Separator', 'on', ...
                'MenuSelectedFcn', @(~, ~)obj.beginEpochGroup(), 'Enable', 'off');
            obj.menuEndEpochGroup = uimenu(documentMenu, 'Text', 'End Epoch Group   Ctrl+E', ...
                'MenuSelectedFcn', @(~, ~)obj.endEpochGroup(), 'Enable', 'off');
            configureMenu = uimenu(obj.fig, 'Text', 'Configure');
            uimenu(configureMenu, 'Text', 'Devices...', 'MenuSelectedFcn', @(~, ~)obj.menuConfigureDevices());
            viewMenu = uimenu(obj.fig, 'Text', 'View');
            uimenu(viewMenu, 'Text', 'Refresh', 'Accelerator', 'R', 'MenuSelectedFcn', @(~, ~)obj.refresh());

            % Main layout: use absolute positioning with splitters
            % Leave 24px at the bottom for the footer label
            w = obj.fig.Position(3);
            h = obj.fig.Position(4);
            mainPanel = uipanel(obj.fig, 'BorderType', 'none', 'Units', 'pixels', ...
                'Position', [0 24 w h - 24], 'BackgroundColor', [0.94 0.94 0.94]);
            footerPanel = uipanel(obj.fig, 'BorderType', 'none', 'Units', 'pixels', ...
                'Position', [0 0 w 24], 'BackgroundColor', [0.94 0.94 0.94]);
            obj.fig.SizeChangedFcn = @(~,~) obj.onFigureResize(mainPanel, footerPanel);

            % Horizontal splitter: tree (left) | right panels
            obj.hSplitter = symphonyui.ui.Splitter(mainPanel, 'horizontal', 0.30);

            % Tree in the left panel
            treeGrid = uigridlayout(obj.hSplitter.LeftOrTop, [1 1]);
            treeGrid.Padding = [4 4 4 4];
            obj.tree = uitree(treeGrid, 'FontSize', 12);
            obj.tree.Layout.Row = 1;
            obj.tree.Layout.Column = 1;
            obj.tree.SelectionChangedFcn = @(s, e) obj.onTreeSelectionChanged(s, e);
            obj.buildTreeContextMenus();

            % Vertical splitter in the right panel: detail cards (top) | tabs (bottom)
            obj.vSplitter = symphonyui.ui.Splitter(obj.hSplitter.RightOrBottom, 'vertical', 0.55);

            obj.cardStack = uipanel(obj.vSplitter.LeftOrTop, 'BorderType', 'none', ...
                'BackgroundColor', [1 1 1]);
            % Vertical scroll when the detail area is shorter than the stacked card content (R2022b+ uifigure).
            if isprop(obj.cardStack, 'Scrollable')
                obj.cardStack.Scrollable = 'on';
            end
            % SizeChangedFcn does not run while AutoResizeChildren is 'on' (MATLAB warning).
            if isprop(obj.cardStack, 'AutoResizeChildren')
                obj.cardStack.AutoResizeChildren = 'off';
            end
            obj.cardStack.SizeChangedFcn = @(~,~)obj.refreshCardStackScrollExtent();
            obj.buildDetailCards();

            obj.annoTabGroup = uitabgroup(obj.vSplitter.RightOrBottom);

            tabProp = uitab(obj.annoTabGroup, 'Title', 'Properties');
            tabKey = uitab(obj.annoTabGroup, 'Title', 'Keywords');
            tabNotes = uitab(obj.annoTabGroup, 'Title', 'Notes');
            tabParam = uitab(obj.annoTabGroup, 'Title', 'Parameters');

            % Fill each tab with uigridlayout — fixed Position [560 220] clipped when the tab area was short.
            obj.propTabGrid = uigridlayout(tabProp, [1 1]);
            obj.propTabGrid.Padding = [4 4 4 4];
            obj.propTabGrid.RowHeight = {'1x'};
            obj.propTabGrid.ColumnWidth = {'1x'};
            % Standard table for generic entities
            obj.propTable = uitable(obj.propTabGrid, 'ColumnName', {'Name', 'Value'}, ...
                'ColumnEditable', [false true], ...
                'ColumnWidth', {'fit', 'auto'}, ...
                'FontSize', 11, ...
                'CellEditCallback', @(s, e) obj.onPropertyCellEdit(s, e));
            obj.propTable.Layout.Row = 1;
            obj.propTable.Layout.Column = 1;
            % Dynamic grid for experiment description (with dropdowns)
            obj.propDynamicGrid = uigridlayout(obj.propTabGrid, [1 2]);
            obj.propDynamicGrid.ColumnWidth = {100, '1x'};
            obj.propDynamicGrid.RowSpacing = 2;
            obj.propDynamicGrid.Padding = [2 2 2 2];
            obj.propDynamicGrid.Scrollable = 'on';
            obj.propDynamicGrid.Layout.Row = 1;
            obj.propDynamicGrid.Layout.Column = 1;
            obj.propDynamicGrid.Visible = 'off';

            gKey = uigridlayout(tabKey, [1 1]);
            gKey.Padding = [4 4 4 4];
            obj.keywordsTable = uitable(gKey, 'ColumnName', {'Keyword'}, 'ColumnEditable', [false], 'FontSize', 11);
            obj.keywordsTable.Layout.Row = 1;
            obj.keywordsTable.Layout.Column = 1;

            gNotes = uigridlayout(tabNotes, [1 1]);
            gNotes.Padding = [4 4 4 4];
            obj.notesTable = uitable(gNotes, 'ColumnName', {'Time', 'Text'}, ...
                'ColumnEditable', [false false], 'ColumnWidth', {'fit', 'auto'}, 'FontSize', 11);
            obj.notesTable.Layout.Row = 1;
            obj.notesTable.Layout.Column = 1;

            gParam = uigridlayout(tabParam, [1 1]);
            gParam.Padding = [4 4 4 4];
            obj.parametersTable = uitable(gParam, 'ColumnName', {'Name', 'Value'}, ...
                'ColumnEditable', [false false], 'ColumnWidth', {'fit', 'auto'}, 'FontSize', 11);
            obj.parametersTable.Layout.Row = 1;
            obj.parametersTable.Layout.Column = 1;

            footerGrid = uigridlayout(footerPanel, [1 1]);
            footerGrid.Padding = [12 0 4 0];
            obj.footerLabel = uilabel(footerGrid, 'FontSize', 11, 'FontColor', [0.35 0.35 0.35], ...
                'Text', 'HDF document state is owned by Symphony.Acquisition (HdfEpochDocumentStore) via AcquisitionHost.');
        end

        function buildDetailCards(obj)
            W = obj.cardStack;
            obj.cardEmpty = uipanel(W, 'BorderType', 'line', 'BackgroundColor', [1 1 1], ...
                'Visible', 'on');
            uilabel(obj.cardEmpty, 'Position', [12 120 400 22], 'Text', 'Select an entity in the tree.', ...
                'FontSize', 11, 'HorizontalAlignment', 'center');

            obj.cardExperiment = uipanel(W, 'BorderType', 'line', 'BackgroundColor', [1 1 1], ...
                'Visible', 'off');
            g = uigridlayout(obj.cardExperiment, [3 2]);
            g.Padding = [6 6 6 6];
            g.RowSpacing = 2;
            g.RowHeight = {22, 22, 22};
            g.ColumnWidth = {70, '1x'};
            g.Scrollable = 'on';
            obj.expGrid = g;
            L1 = uilabel(g, 'Text', 'Purpose:', 'HorizontalAlignment', 'right', 'FontSize', 11);
            L1.Layout.Row = 1;
            L1.Layout.Column = 1;
            obj.expPurposeField = uieditfield(g, 'FontSize', 11, 'ValueChangedFcn', @(s, e) obj.commitExperimentPurpose());
            obj.expPurposeField.Layout.Row = 1;
            obj.expPurposeField.Layout.Column = 2;
            L2 = uilabel(g, 'Text', 'Start time:', 'HorizontalAlignment', 'right', 'FontSize', 11);
            L2.Layout.Row = 2;
            L2.Layout.Column = 1;
            obj.expStartLabel = uilabel(g, 'Text', '', 'FontSize', 11);
            obj.expStartLabel.Layout.Row = 2;
            obj.expStartLabel.Layout.Column = 2;
            L3 = uilabel(g, 'Text', 'End time:', 'HorizontalAlignment', 'right', 'FontSize', 11);
            L3.Layout.Row = 3;
            L3.Layout.Column = 1;
            obj.expEndLabel = uilabel(g, 'Text', '', 'FontSize', 11);
            obj.expEndLabel.Layout.Row = 3;
            obj.expEndLabel.Layout.Column = 2;

            obj.cardSource = uipanel(W, 'BorderType', 'line', 'BackgroundColor', [1 1 1], ...
                'Visible', 'off');
            gs = uigridlayout(obj.cardSource, [2 2]);
            gs.Padding = [6 6 6 6];
            gs.RowSpacing = 2;
            gs.RowHeight = {22, '1x'};
            gs.ColumnWidth = {40, '1x'};
            Ls = uilabel(gs, 'Text', 'Label:', 'HorizontalAlignment', 'right', 'FontSize', 11);
            Ls.Layout.Row = 1;
            Ls.Layout.Column = 1;
            obj.srcLabelField = uieditfield(gs, 'FontSize', 11, 'ValueChangedFcn', @(s, e) obj.commitSourceLabel());
            obj.srcLabelField.Layout.Row = 1;
            obj.srcLabelField.Layout.Column = 2;

            obj.cardEpochGroup = uipanel(W, 'BorderType', 'line', 'BackgroundColor', [1 1 1], ...
                'Visible', 'off', 'AutoResizeChildren', 'on');
            grpOuter = uigridlayout(obj.cardEpochGroup, [2 1]);
            grpOuter.Padding = [0 0 0 0];
            grpOuter.RowSpacing = 2;
            grpOuter.RowHeight = {100, '1x'};  % fixed header + scrollable description
            grpOuter.ColumnWidth = {'1x'};

            % Fixed header: Label, Start, End, Source
            gg = uigridlayout(grpOuter, [4 2]);
            gg.Layout.Row = 1; gg.Layout.Column = 1;
            gg.Padding = [6 6 6 2];
            gg.RowSpacing = 2;
            gg.RowHeight = {22, 22, 22, 22};
            gg.ColumnWidth = {70, '1x'};
            g1 = uilabel(gg, 'Text', 'Label:', 'HorizontalAlignment', 'right', 'FontSize', 11);
            g1.Layout.Row = 1;
            g1.Layout.Column = 1;
            obj.grpLabelField = uieditfield(gg, 'FontSize', 11, 'ValueChangedFcn', @(s, e) obj.commitEpochGroupLabel());
            obj.grpLabelField.Layout.Row = 1;
            obj.grpLabelField.Layout.Column = 2;
            g2 = uilabel(gg, 'Text', 'Start time:', 'HorizontalAlignment', 'right', 'FontSize', 11);
            g2.Layout.Row = 2;
            g2.Layout.Column = 1;
            obj.grpStartLabel = uilabel(gg, 'Text', '', 'FontSize', 11);
            obj.grpStartLabel.Layout.Row = 2;
            obj.grpStartLabel.Layout.Column = 2;
            g3 = uilabel(gg, 'Text', 'End time:', 'HorizontalAlignment', 'right', 'FontSize', 11);
            g3.Layout.Row = 3;
            g3.Layout.Column = 1;
            obj.grpEndLabel = uilabel(gg, 'Text', '', 'FontSize', 11);
            obj.grpEndLabel.Layout.Row = 3;
            obj.grpEndLabel.Layout.Column = 2;
            g4 = uilabel(gg, 'Text', 'Source:', 'HorizontalAlignment', 'right', 'FontSize', 11);
            g4.Layout.Row = 4;
            g4.Layout.Column = 1;
            obj.grpSourceDropDown = uidropdown(gg, 'Editable', 'off', 'FontSize', 11);
            obj.grpSourceDropDown.Layout.Row = 4;
            obj.grpSourceDropDown.Layout.Column = 2;

            % Scrollable grid for epoch group description properties
            obj.grpDescGrid = uigridlayout(grpOuter, [1 2]);
            obj.grpDescGrid.Layout.Row = 2; obj.grpDescGrid.Layout.Column = 1;
            obj.grpDescGrid.ColumnWidth = {100, '1x'};
            obj.grpDescGrid.RowSpacing = 2;
            obj.grpDescGrid.Padding = [6 2 6 2];
            obj.grpDescGrid.Scrollable = 'on';

            obj.cardEpochBlock = uipanel(W, 'BorderType', 'line', 'BackgroundColor', [1 1 1], ...
                'Visible', 'off');
            gb = uigridlayout(obj.cardEpochBlock, [3 2]);
            gb.Padding = [6 6 6 6];
            gb.RowSpacing = 2;
            gb.RowHeight = {22, 22, '1x'};
            gb.ColumnWidth = {80, '1x'};
            b1 = uilabel(gb, 'Text', 'Protocol ID:', 'HorizontalAlignment', 'right', 'FontSize', 11);
            b1.Layout.Row = 1;
            b1.Layout.Column = 1;
            obj.blkProtocolLabel = uilabel(gb, 'Text', '', 'FontSize', 11);
            obj.blkProtocolLabel.Layout.Row = 1;
            obj.blkProtocolLabel.Layout.Column = 2;
            b2 = uilabel(gb, 'Text', 'Times:', 'HorizontalAlignment', 'right', 'FontSize', 11);
            b2.Layout.Row = 2;
            b2.Layout.Column = 1;
            obj.blkTimesLabel = uilabel(gb, 'Text', '', 'FontSize', 11);
            obj.blkTimesLabel.Layout.Row = 2;
            obj.blkTimesLabel.Layout.Column = 2;

            obj.cardEpoch = uipanel(W, 'BorderType', 'line', 'BackgroundColor', [1 1 1], ...
                'Position', [0 0 1 1], 'Units', 'normalized', 'Visible', 'off', ...
                'Title', 'Epoch preview', 'TitlePosition', 'centertop', ...
                'FontSize', 10, ...
                'AutoResizeChildren', 'off');
            egl = uigridlayout(obj.cardEpoch, [2 1]);
            egl.Padding = [4 4 4 4];
            egl.RowSpacing = 2;
            egl.RowHeight = {24, '1x'};
            egl.ColumnWidth = {'1x'};
            topRow = uigridlayout(egl, [1 2]);
            topRow.Layout.Row = 1;
            topRow.Layout.Column = 1;
            topRow.ColumnWidth = {36, '1x'};
            topRow.Padding = [0 0 0 0];
            Lshow = uilabel(topRow, 'Text', 'Show:', 'HorizontalAlignment', 'right', 'FontSize', 11);
            Lshow.Layout.Row = 1;
            Lshow.Layout.Column = 1;
            obj.epochResponseDropDown = uidropdown(topRow, 'Editable', 'off', ...
                'Items', {'All traces'}, ...
                'Value', 'All traces', ...
                'Enable', 'off', ...
                'FontSize', 11, ...
                'ValueChangedFcn', @(s, e)obj.onEpochResponseDeviceChanged());
            obj.epochResponseDropDown.Layout.Row = 1;
            obj.epochResponseDropDown.Layout.Column = 2;
            obj.epochAxes = uiaxes(egl);
            obj.epochAxes.Layout.Row = 2;
            obj.epochAxes.Layout.Column = 1;
            obj.epochAxes.XLabel.String = 'Time (s)';
            obj.epochAxes.YLabel.String = 'Amplitude';
            obj.epochAxes.Title.String = obj.epochDefaultTitleText();
            obj.epochAxes.Title.FontSize = 10;
            obj.epochAxes.FontSize = 9;
            grid(obj.epochAxes, 'on');
            obj.epochAxesAddCenterPlaceholder('Select an epoch in the tree to plot waveforms.');
            % AutoResizeChildren must be 'off' or MATLAB warns SizeChangedFcn will not run (see uistack).
            obj.cardEpoch.SizeChangedFcn = @(~,~)obj.refreshEpochAxesLayout();
            % Single visible stacked card + collapsed hidden cards (see layoutDetailStack).
            obj.layoutDetailStack('empty');
        end

        function layoutDetailStack(obj, which)
            % Stacked cards: toggle Visible and uistack; size all cards to
            % fill the cardStack using explicit pixel positions (required
            % because AutoResizeChildren is 'off').
            pairs = {
                'empty', obj.cardEmpty;
                'experiment', obj.cardExperiment;
                'source', obj.cardSource;
                'epoch_group', obj.cardEpochGroup;
                'epoch_block', obj.cardEpochBlock;
                'epoch', obj.cardEpoch
                };
            for r = 1:size(pairs, 1)
                id = pairs{r, 1};
                p = pairs{r, 2};
                on = strcmp(id, which);
                try
                    if on
                        p.Visible = 'on';
                    else
                        p.Visible = 'off';
                    end
                catch
                end
            end
            obj.refreshCardStackScrollExtent();
        end

        function refreshCardStackScrollExtent(obj)
            % Resize all cards to fill the cardStack. Since AutoResizeChildren
            % is 'off', normalized positioning doesn't auto-resize — we must
            % set explicit pixel sizes. When the viewport is shorter than
            % minH, cards get minH so Scrollable kicks in.
            if isempty(obj.cardStack) || ~isvalid(obj.cardStack)
                return;
            end
            try
                pp = getpixelposition(obj.cardStack);
                vw = max(1, pp(3));
                vh = max(1, pp(4));
                minH = 520;
                cardH = max(vh, minH);
                cards = {obj.cardEmpty, obj.cardExperiment, obj.cardSource, ...
                    obj.cardEpochGroup, obj.cardEpochBlock, obj.cardEpoch};
                for k = 1:numel(cards)
                    p = cards{k};
                    if isempty(p) || ~isvalid(p)
                        continue;
                    end
                    p.Units = 'pixels';
                    p.Position = [0 0 vw cardH];
                end
            catch
            end
        end

        function buildTreeContextMenus(obj)
            % Context menus are now created per-node in populateTree/addEpochGroupBranch
            % so each node gets its own menu that selects the correct node on open.
            % These shared handles are kept as templates but not directly assigned.
            obj.cmEpochGroup = [];
            obj.cmEpochBlock = [];
            obj.cmEpoch = [];
            obj.cmSource = [];
        end

        function cm = makeEpochGroupContextMenu(obj, node)
            cm = uicontextmenu(obj.fig);
            cm.ContextMenuOpeningFcn = @(~,~) obj.selectTreeNode(node);
            uimenu(cm, 'Text', 'Split Epoch Group...', 'MenuSelectedFcn', @(~,~)obj.onTreeMenuSplitEpochGroup());
            uimenu(cm, 'Text', 'Merge Epoch Groups...', 'MenuSelectedFcn', @(~,~)obj.onTreeMenuMergeEpochGroups());
            uimenu(cm, 'Text', 'Delete', 'Separator', 'on', 'MenuSelectedFcn', @(~,~)obj.onTreeMenuDeleteEntity());
        end

        function cm = makeEpochBlockContextMenu(obj, node)
            cm = uicontextmenu(obj.fig);
            cm.ContextMenuOpeningFcn = @(~,~) obj.selectTreeNode(node);
            uimenu(cm, 'Text', 'Split Epoch Group (after this block)...', 'MenuSelectedFcn', @(~,~)obj.onTreeMenuSplitAfterThisBlock());
            uimenu(cm, 'Text', 'Delete', 'Separator', 'on', 'MenuSelectedFcn', @(~,~)obj.onTreeMenuDeleteEntity());
        end

        function cm = makeEpochContextMenu(obj, node)
            cm = uicontextmenu(obj.fig);
            cm.ContextMenuOpeningFcn = @(~,~) obj.selectTreeNode(node);
            uimenu(cm, 'Text', 'Delete', 'MenuSelectedFcn', @(~,~)obj.onTreeMenuDeleteEntity());
        end

        function cm = makeSourceContextMenu(obj, node)
            cm = uicontextmenu(obj.fig);
            cm.ContextMenuOpeningFcn = @(~,~) obj.selectTreeNode(node);
            uimenu(cm, 'Text', 'Add Child Source...', 'MenuSelectedFcn', @(~,~)obj.onTreeMenuAddChildSource());
            uimenu(cm, 'Text', 'Delete', 'Separator', 'on', 'MenuSelectedFcn', @(~,~)obj.onTreeMenuDeleteEntity());
        end

        function selectTreeNode(obj, node)
            % Select the specified tree node (called from ContextMenuOpeningFcn).
            try
                obj.tree.SelectedNodes = node;
                obj.onTreeSelectionChanged(obj.tree, []);
            catch
            end
        end

        function nd = getSelectedTreeNodeData(obj)
            nd = [];
            try
                if isempty(obj.tree) || ~isvalid(obj.tree)
                    return;
                end
                if isempty(obj.tree.SelectedNodes)
                    return;
                end
                n = obj.tree.SelectedNodes(1);
                if isempty(n.NodeData)
                    return;
                end
                nd = n.NodeData;
            catch
            end
        end

        function onTreeMenuAddChildSource(obj)
            nd = obj.getSelectedTreeNodeData();
            if isempty(nd) || ~strcmp(char(string(nd.kind)), 'source')
                return;
            end
            parentSourceId = char(string(nd.id));
            try
                searchPaths = symphonyui.ui.SymphonyDataManager.buildSearchPaths();
                result = symphonyui.ui.AddSourceDialog.showBlocking( ...
                    obj.fig, obj.host, searchPaths, parentSourceId);
                if ~isempty(result)
                    obj.refresh();  % full rebuild to show new child source
                    obj.notifyAcquireRefresh();
                end
            catch ex
                fprintf(2, '\n=== Add Child Source Error ===\n%s\n', getReport(ex, 'extended'));
                obj.showError(ex.message, 'Add Child Source Error');
            end
        end

        function onTreeMenuDeleteEntity(obj)
            nd = obj.getSelectedTreeNodeData();
            if isempty(nd)
                return;
            end
            kind = char(string(nd.kind));
            if ismember(kind, {'experiment', 'sources_folder', 'epoch_groups_folder'})
                return;
            end
            answer = uiconfirm(obj.fig, sprintf('Delete this %s? This cannot be undone.', kind), ...
                'Confirm delete', 'Icon', 'warning');
            if ~strcmp(answer, 'OK')
                return;
            end
            try
                obj.awaitTask(obj.host.DeleteEntityAsync(kind, char(string(nd.id))));
                obj.notifyAcquireRefresh();
                obj.refresh(true);  % Full rebuild — delete removes tree nodes
            catch ex
                obj.showError(ex.message, 'Data Manager');
            end
        end

        function onTreeMenuSplitEpochGroup(obj)
            try
                nd = obj.getSelectedTreeNodeData();
                if isempty(nd) || ~strcmp(char(string(nd.kind)), 'epoch_group')
                    return;
                end
                dm = obj.lastDm;
                if isempty(dm)
                    return;
                end
                gid = char(string(nd.id));
                [blockIds, blockLabels] = obj.epochBlocksInGroup(dm, gid);
                if numel(blockIds) < 2
                    uialert(obj.fig, 'Split requires at least two epoch blocks in this group.', 'Split Epoch Group');
                    return;
                end

                % UIFigure-compatible selection dialog
                [sel, ok] = listdlg('PromptString', ...
                    {'Split after which block?', '(First group keeps blocks before;', 'second group starts after)'}, ...
                    'ListString', blockLabels, 'SelectionMode', 'single', ...
                    'Name', 'Split Epoch Group', 'ListSize', [420 200]);
                if ~ok || isempty(sel)
                    return;
                end
                bid = blockIds{sel};
                obj.awaitTask(obj.host.SplitEpochGroupAfterBlockAsync(gid, bid));
                obj.notifyAcquireRefresh();
                obj.refresh(true);  % Full rebuild — split changes tree structure
            catch ex
                fprintf(2, '\n=== Split Epoch Group Error ===\n%s\n', getReport(ex, 'extended'));
                obj.showError(ex.message, 'Split Epoch Group');
            end
        end

        function onTreeMenuSplitAfterThisBlock(obj)
            nd = obj.getSelectedTreeNodeData();
            if isempty(nd) || ~strcmp(char(string(nd.kind)), 'epoch_block')
                return;
            end
            dm = obj.lastDm;
            if isempty(dm)
                return;
            end
            bid = char(string(nd.id));
            gid = obj.epochGroupIdForBlock(dm, bid);
            if isempty(gid)
                uialert(obj.fig, 'Could not resolve epoch group for this block.', 'Split Epoch Group');
                return;
            end
            try
                obj.awaitTask(obj.host.SplitEpochGroupAfterBlockAsync(gid, bid));
                obj.notifyAcquireRefresh();
                obj.refresh(true);  % Full rebuild — split changes tree structure
            catch ex
                obj.showError(ex.message, 'Split Epoch Group');
            end
        end

        function onTreeMenuMergeEpochGroups(obj)
            nd = obj.getSelectedTreeNodeData();
            if isempty(nd) || ~strcmp(char(string(nd.kind)), 'epoch_group')
                return;
            end
            dm = obj.lastDm;
            if isempty(dm)
                return;
            end
            gid = char(string(nd.id));
            parentId = obj.parentGroupIdForEpochGroup(dm, gid);
            [candIds, candLabels] = obj.siblingEpochGroups(dm, gid, parentId);
            if isempty(candIds)
                uialert(obj.fig, 'No other epoch group at this hierarchy level to merge with.', 'Merge Epoch Groups');
                return;
            end
            [sel, ok] = listdlg('PromptString', {'Select the group to merge with the selected group (must be adjacent in time):'}, ...
                'ListString', candLabels, 'SelectionMode', 'single', 'Name', 'Merge Epoch Groups', ...
                'ListSize', [420 200]);
            if ~ok || isempty(sel)
                return;
            end
            otherId = candIds{sel};
            try
                obj.awaitTask(obj.host.MergeEpochGroupsAsync(gid, otherId));
                obj.notifyAcquireRefresh();
                obj.refresh(true);  % Full rebuild — merge changes tree structure
            catch ex
                obj.showError(ex.message, 'Merge Epoch Groups');
            end
        end

        function pid = parentGroupIdForEpochGroup(obj, dm, groupId)
            pid = [];
            n = SymphonyAppUtil.getNetCount(dm.EpochGroups);
            for i = 1:n
                g = SymphonyAppUtil.getNetItem(dm.EpochGroups, i);
                if strcmp(char(string(g.Id)), char(string(groupId)))
                    pid = g.ParentGroupId;
                    return;
                end
            end
        end

        function [ids, labels] = siblingEpochGroups(obj, dm, selectedId, parentId)
            % Return only adjacent (previous and next) sibling epoch groups,
            % since only adjacent groups can be merged.
            ids = {};
            labels = {};
            n = SymphonyAppUtil.getNetCount(dm.EpochGroups);

            selectedId = char(string(selectedId));

            % Collect all siblings (including selected) in order
            sibIds = {};
            sibLabels = {};
            for i = 1:n
                g = SymphonyAppUtil.getNetItem(dm.EpochGroups, i);
                gid = char(string(g.Id));
                pg = g.ParentGroupId;
                match = obj.sameParentGroupId(parentId, pg);
                if match
                    sibIds{end + 1} = gid; %#ok<AGROW>
                    sibLabels{end + 1} = char(g.Label); %#ok<AGROW>
                end
            end

            % Find the index of the selected group
            selIdx = find(strcmp(sibIds, selectedId));
            if isempty(selIdx)
                return;
            end

            % Only include the immediately previous and next siblings
            adjacentIdx = [];
            if selIdx > 1
                adjacentIdx(end + 1) = selIdx - 1;
            end
            if selIdx < numel(sibIds)
                adjacentIdx(end + 1) = selIdx + 1;
            end

            for j = 1:numel(adjacentIdx)
                ai = adjacentIdx(j);
                ids{end + 1} = sibIds{ai}; %#ok<AGROW>
                labels{end + 1} = sprintf('%s (%s)', sibLabels{ai}, sibIds{ai}); %#ok<AGROW>
            end
        end

        function tf = sameParentGroupId(~, a, b)
            if isempty(a) && isempty(b)
                tf = true;
            elseif isempty(a) || isempty(b)
                tf = false;
            else
                tf = strcmp(char(string(a)), char(string(b)));
            end
        end

        function gid = epochGroupIdForBlock(obj, dm, blockId)
            gid = '';
            n = SymphonyAppUtil.getNetCount(dm.EpochBlocks);
            for i = 1:n
                b = SymphonyAppUtil.getNetItem(dm.EpochBlocks, i);
                if strcmp(char(string(b.Id)), char(string(blockId)))
                    gid = char(string(b.EpochGroupId));
                    return;
                end
            end
        end

        function [blockIds, blockLabels] = epochBlocksInGroup(obj, dm, groupId)
            blockIds = {};
            blockLabels = {};
            n = SymphonyAppUtil.getNetCount(dm.EpochBlocks);
            for i = 1:n
                b = SymphonyAppUtil.getNetItem(dm.EpochBlocks, i);
                if strcmp(char(string(b.EpochGroupId)), char(string(groupId)))
                    blockIds{end + 1} = char(string(b.Id)); %#ok<AGROW>
                    blockLabels{end + 1} = symphonyui.ui.SymphonyDataManager.blockLabel(b); %#ok<AGROW>
                end
            end
        end

        function refreshEpochAxesLayout(obj)
            if isempty(obj.epochAxes) || ~isvalid(obj.epochAxes)
                return;
            end
            try
                % Axes live in uigridlayout — do not set Position/Units here.
                % Axes chrome: ensure contrast vs white panel (some themes drew white-on-white).
                obj.epochAxes.Color = [0.94 0.94 0.94];
                obj.epochAxes.XColor = [0.2 0.2 0.2];
                obj.epochAxes.YColor = [0.2 0.2 0.2];
            catch
            end
            try
                obj.epochAxes.Title.Color = [0.05 0.05 0.05];
            catch
            end
            try
                obj.epochAxes.XLabel.Color = [0.2 0.2 0.2];
                obj.epochAxes.YLabel.Color = [0.2 0.2 0.2];
            catch
            end
        end

        function menuConfigureDevices(obj)
            if ~isempty(obj.onConfigureDevices)
                obj.onConfigureDevices();
            else
                uialert(obj.parentFigure, 'Configure Devices is not wired.', 'Data Manager');
            end
        end

        function addSourceTreeBranches(obj, parentNode, dm, ic, parentId)
            nSrc = SymphonyAppUtil.getNetCount(dm.Sources);
            for i = 1:nSrc
                s = SymphonyAppUtil.getNetItem(dm.Sources, i);
                pid = s.ParentSourceId;
                if isempty(pid)
                    pc = '';
                else
                    pc = char(pid);
                end
                if ~strcmp(pc, parentId)
                    continue;
                end
                nid = char(s.Id);
                sn = uitreenode(parentNode, 'Text', char(s.Label), 'Icon', ic('source.png'));
                sn.NodeData = struct('kind', 'source', 'id', nid);
                try
                    sn.ContextMenu = obj.makeSourceContextMenu(sn);
                catch
                end
                obj.addSourceTreeBranches(sn, dm, ic, nid);
            end
        end

        function addNewTreeNodes(obj, dm)
            % Lightweight incremental update: only add new epoch groups
            % and epoch blocks that aren't already in the tree.
            % Much faster than a full populateTree rebuild.
            try
                % Collect existing node IDs from the tree
                existingIds = obj.collectExistingNodeIds(obj.tree);

                ic = @obj.iconIfAny;

                % Check for new epoch groups
                groups = obj.topLevelGroups(dm);
                for k = 1:numel(groups)
                    gid = char(groups{k}.Id);
                    if ~existingIds.isKey(gid)
                        % New epoch group — find the Epoch Groups folder
                        gfNode = obj.findNodeByKind(obj.tree, 'epoch_groups_folder');
                        if ~isempty(gfNode)
                            obj.addEpochGroupBranch(gfNode, groups{k}, dm, ic);
                        end
                    else
                        % Existing epoch group — check for new epoch blocks
                        egNode = existingIds(gid);
                        nBlocks = SymphonyAppUtil.getNetCount(dm.EpochBlocks);
                        for bi = 1:nBlocks
                            blk = SymphonyAppUtil.getNetItem(dm.EpochBlocks, bi);
                            try
                                blkParent = char(blk.EpochGroupId);
                            catch
                                blkParent = '';
                            end
                            if strcmp(blkParent, gid)
                                blkId = char(blk.Id);
                                if ~existingIds.isKey(blkId)
                                    % New epoch block
                                    blkNode = uitreenode(egNode, ...
                                        'Text', symphonyui.ui.SymphonyDataManager.blockLabel(blk), ...
                                        'Icon', ic('block.png'));
                                    blkNode.NodeData = struct('kind', 'epoch_block', 'id', blkId);
                                end
                            end
                        end
                    end
                end
            catch ex
                fprintf(2, 'addNewTreeNodes error: %s\n', ex.message);
            end
        end

        function ids = collectExistingNodeIds(~, tree)
            % Recursively collect all node IDs into a map for fast lookup.
            ids = containers.Map();
            nodes = tree.Children;
            stack = {};
            for i = 1:numel(nodes)
                stack{end+1} = nodes(i); %#ok<AGROW>
            end
            while ~isempty(stack)
                n = stack{end};
                stack(end) = [];
                try
                    if ~isempty(n.NodeData) && isfield(n.NodeData, 'id') && ~isempty(n.NodeData.id)
                        ids(n.NodeData.id) = n;
                    end
                catch
                end
                ch = n.Children;
                for i = 1:numel(ch)
                    stack{end+1} = ch(i); %#ok<AGROW>
                end
            end
        end

        function node = findNodeByKind(~, tree, kind)
            % Find first node with the given kind in the tree.
            node = [];
            stack = {};
            ch = tree.Children;
            for i = 1:numel(ch)
                stack{end+1} = ch(i); %#ok<AGROW>
            end
            while ~isempty(stack)
                n = stack{end};
                stack(end) = [];
                try
                    if ~isempty(n.NodeData) && isfield(n.NodeData, 'kind') && strcmp(n.NodeData.kind, kind)
                        node = n;
                        return;
                    end
                catch
                end
                nch = n.Children;
                for i = 1:numel(nch)
                    stack{end+1} = nch(i); %#ok<AGROW>
                end
            end
        end

        function populateTree(obj, dm)
            delete(obj.tree.Children);
            ic = @obj.iconIfAny;

            root = uitreenode(obj.tree, 'Text', obj.experimentRootLabel(dm), 'Icon', ic('experiment.png'));
            root.NodeData = struct('kind', 'experiment', 'id', obj.experimentId(dm));

            sf = uitreenode(root, 'Text', 'Sources', 'Icon', ic('folder.png'));
            sf.NodeData = struct('kind', 'sources_folder', 'id', '');

            obj.addSourceTreeBranches(sf, dm, ic, '');

            gf = uitreenode(root, 'Text', 'Epoch Groups', 'Icon', ic('folder.png'));
            gf.NodeData = struct('kind', 'epoch_groups_folder', 'id', '');

            % Pre-group epoch blocks by epoch group ID to avoid O(n^2) lookups
            blocksByGroup = containers.Map();
            nBlocks = SymphonyAppUtil.getNetCount(dm.EpochBlocks);
            for bi = 1:nBlocks
                b = SymphonyAppUtil.getNetItem(dm.EpochBlocks, bi);
                bgid = char(b.EpochGroupId);
                if ~blocksByGroup.isKey(bgid)
                    blocksByGroup(bgid) = {};
                end
                blocks = blocksByGroup(bgid);
                blocks{end+1} = b; %#ok<AGROW>
                blocksByGroup(bgid) = blocks;
            end

            groups = obj.topLevelGroups(dm);
            for k = 1:numel(groups)
                obj.addEpochGroupBranch(gf, groups{k}, dm, ic, blocksByGroup);
            end

            expand(root);
            expand(sf);
            expand(gf);
        end

        function id = experimentId(obj, dm)
            id = '';
            try
                ex = dm.Experiment;
                if isempty(ex)
                    return;
                end
                id = char(ex.Id);
            catch
            end
        end

        function lbl = experimentRootLabel(obj, dm)
            try
                ex = dm.Experiment;
                if isempty(ex)
                    fp = char(dm.CurrentFilePath);
                    if isempty(fp)
                        lbl = 'Experiment';
                    else
                        lbl = ['Experiment — ', fp];
                    end
                    return;
                end
                lbl = char(ex.DisplayName);
            catch
                lbl = 'Experiment';
            end
        end

        function groups = topLevelGroups(obj, dm)
            groups = {};
            n = SymphonyAppUtil.getNetCount(dm.EpochGroups);
            for i = 1:n
                g = SymphonyAppUtil.getNetItem(dm.EpochGroups, i);
                pid = g.ParentGroupId;
                if isempty(pid)
                    groups{end + 1} = g; %#ok<AGROW>
                    continue;
                end
                try
                    pc = char(pid);
                catch
                    pc = '';
                end
                if isempty(pc)
                    groups{end + 1} = g; %#ok<AGROW>
                end
            end
        end

        function addEpochGroupBranch(obj, parentNode, grp, dm, ic, blocksByGroup)
            gid = char(grp.Id);
            src = obj.sourceLabelForId(dm, grp.SourceId);
            label = sprintf('%s (%s)', char(grp.Label), src);
            label = [label, symphonyui.ui.SymphonyDataManager.groupProtocolSuffix(dm, gid)];
            if logical(grp.IsCurrent)
                label = [label, ' *'];
            end
            iconFile = 'group.png';
            if logical(grp.IsCurrent)
                iconFile = 'group_current.png';
            end
            gn = uitreenode(parentNode, 'Text', label, 'Icon', ic(iconFile));
            gn.NodeData = struct('kind', 'epoch_group', 'id', gid);
            try
                gn.ContextMenu = obj.makeEpochGroupContextMenu(gn);
            catch
            end

            % Use pre-grouped blocks (O(1) lookup) instead of scanning all blocks (O(n))
            if nargin >= 6 && blocksByGroup.isKey(gid)
                blocks = blocksByGroup(gid);
                for i = 1:numel(blocks)
                    b = blocks{i};
                    bid = char(b.Id);
                    bn = uitreenode(gn, 'Text', symphonyui.ui.SymphonyDataManager.blockLabel(b), 'Icon', ic('block.png'));
                    bn.NodeData = struct('kind', 'epoch_block', 'id', bid);
                    try
                        bn.ContextMenu = obj.makeEpochBlockContextMenu(bn);
                    catch
                    end
                    % Epochs are loaded lazily when the block is selected
                    % (see onTreeSelectionChanged). Don't load them here.
                end
            end

            % Nested epoch groups
            if nargin < 6
                blocksByGroup = containers.Map();
            end
            ng = SymphonyAppUtil.getNetCount(dm.EpochGroups);
            for i = 1:ng
                cg = SymphonyAppUtil.getNetItem(dm.EpochGroups, i);
                pg = cg.ParentGroupId;
                if isempty(pg)
                    continue;
                end
                if strcmp(char(pg), gid)
                    obj.addEpochGroupBranch(gn, cg, dm, ic, blocksByGroup);
                end
            end
        end

        function sl = sourceLabelForId(obj, dm, sourceId)
            sl = '?';
            if isempty(sourceId)
                sl = '(none)';
                return;
            end
            sid = char(sourceId);
            n = SymphonyAppUtil.getNetCount(dm.Sources);
            for i = 1:n
                s = SymphonyAppUtil.getNetItem(dm.Sources, i);
                if strcmp(char(s.Id), sid)
                    sl = char(s.Label);
                    return;
                end
            end
        end

        function pth = iconIfAny(~, fileName)
            root = symphonyui.ui.symphonyAppRoot();
            pth = fullfile(root, 'code', 'src', 'resources', 'icons', fileName);
            if isfile(pth)
                return;
            end
            pth = '';
        end

        function populateEntityTabsEmpty(obj)
            obj.clearAnnotationTables();
        end

        function clearAnnotationTables(obj)
            obj.propTable.Data = cell(0, 2);
            obj.keywordsTable.Data = cell(0, 1);
            obj.notesTable.Data = cell(0, 2);
            obj.parametersTable.Data = cell(0, 2);
        end

        function tf = isFolderKind(~, kind)
            tf = strcmp(kind, 'sources_folder') || strcmp(kind, 'epoch_groups_folder');
        end

        function populateEntityTabs(obj, kind, entityId)
            obj.clearAnnotationTables();
            obj.clearPropDynamicGrid();
            obj.showPropTable();
            if obj.isFolderKind(kind)
                return;
            end
            try
                d = obj.awaitTaskWithResult(obj.host.GetEntityDetailAsync(char(string(kind)), char(string(entityId))));
                obj.fillAnnotationTables(d);
            catch ex
                obj.showError(ex.message, 'Data Manager');
            end
        end

        function fillAnnotationTables(obj, d)
            % Properties
            n = SymphonyAppUtil.getNetCount(d.Properties);
            pr = cell(n, 2);
            for i = 1:n
                r = SymphonyAppUtil.getNetItem(d.Properties, i);
                pr{i, 1} = char(string(r.Name));
                pr{i, 2} = char(string(r.Value));
            end
            obj.propTable.Data = pr;

            % Keywords
            nk = SymphonyAppUtil.getNetCount(d.Keywords);
            kw = cell(nk, 1);
            for i = 1:nk
                kw{i, 1} = char(string(SymphonyAppUtil.getNetItem(d.Keywords, i)));
            end
            obj.keywordsTable.Data = kw;

            % Notes (entity-scoped from HDF)
            nn = SymphonyAppUtil.getNetCount(d.Notes);
            nd = cell(nn, 2);
            for i = 1:nn
                note = SymphonyAppUtil.getNetItem(d.Notes, i);
                nd{i, 1} = char(note.Time.ToString('u'));
                nd{i, 2} = char(note.Text);
            end
            obj.notesTable.Data = nd;

            % Parameters (protocol parameters on epoch block / epoch)
            np = SymphonyAppUtil.getNetCount(d.Parameters);
            pp = cell(np, 2);
            for i = 1:np
                r = SymphonyAppUtil.getNetItem(d.Parameters, i);
                pp{i, 1} = char(string(r.Name));
                pp{i, 2} = char(string(r.Value));
            end
            obj.parametersTable.Data = pp;
        end

        function applySelectionAfterRefresh(obj)
            if isempty(obj.tree.SelectedNodes)
                obj.showCard('empty');
                obj.populateEntityTabsEmpty();
                return;
            end
            obj.onTreeSelectionChanged(obj.tree, []);
        end

        function onFigureKeyPress(obj, event)
            % Consume the Enter key so it does not deselect the current
            % tree node or trigger unwanted UI behavior.
            if strcmp(event.Key, 'return')
                return;  % swallow the event
            end
            % Ctrl+B / Ctrl+E: begin / end epoch group (same as the main window).
            mods = {};
            try
                mods = event.Modifier;
            catch
            end
            if any(strcmpi(mods, 'control')) || any(strcmpi(mods, 'command'))
                switch lower(event.Key)
                    case 'b'
                        if strcmp(obj.menuBeginEpochGroup.Enable, 'on')
                            obj.beginEpochGroup();
                        end
                    case 'e'
                        if strcmp(obj.menuEndEpochGroup.Enable, 'on')
                            obj.endEpochGroup();
                        end
                end
            end
        end

        function onTreeSelectionChanged(obj, src, event)
            % Tree selection is allowed during acquisition — with separate
            % HDF5 libraries (hdf5_symphony.dll), MATLAB reads through its
            % own hdf5.dll while C# writes through hdf5_symphony.dll.
            % Only full refresh (GetDataManagerStateAsync) is blocked.
            % Prefer event.SelectedNodes — tree.SelectedNodes can be stale/empty during this callback.
            nodes = [];
            if nargin >= 3 && ~isempty(event)
                try
                    nodes = event.SelectedNodes;
                catch
                end
            end
            if isempty(nodes) && ~isempty(src)
                try
                    nodes = src.SelectedNodes;
                catch
                end
            end
            if isempty(nodes) && ~isempty(obj.tree)
                drawnow;
                try
                    nodes = obj.tree.SelectedNodes;
                catch
                end
            end
            if isempty(nodes)
                obj.showCard('empty');
                obj.populateEntityTabsEmpty();
                return;
            end
            n = nodes(1);
            if isempty(n.NodeData)
                obj.showCard('empty');
                obj.populateEntityTabsEmpty();
                return;
            end
            nd = n.NodeData;
            obj.currentSelection = nd;
            kind = char(string(nd.kind));
            dm = obj.lastDm;
            eid = char(string(nd.id));
            switch kind
                case 'experiment'
                    obj.showCard('empty');
                    obj.populateEntityTabs(kind, eid);
                    % Properties tab with description-based editable fields
                    obj.fillExperimentProperties();
                case 'source'
                    obj.showCard('empty');
                    obj.populateEntityTabs(kind, eid);
                    % Properties tab with source description fields (incl. label)
                    obj.fillSourceDescriptionProperties(eid);
                case 'epoch_group'
                    obj.showCard('empty');
                    obj.populateEntityTabs(kind, eid);
                    % Properties tab with epoch group description fields (incl. label)
                    obj.fillEpochGroupDescriptionProperties(eid);
                case 'epoch_block'
                    obj.showCard('empty');
                    obj.populateEntityTabs(kind, eid);
                    % Lazy-load epochs under this block if not already loaded
                    obj.loadEpochsForBlock(eid);
                case 'epoch'
                    symphonyui.ui.SymphonyDataManager.trace('epoch: showCard');
                    obj.showCard('epoch');
                    symphonyui.ui.SymphonyDataManager.stepFlush('after showCard');
                    symphonyui.ui.SymphonyDataManager.trace('epoch: fillEpochCard');
                    obj.fillEpochCard(dm, eid);
                    symphonyui.ui.SymphonyDataManager.stepFlush('after fillEpochCard');
                    symphonyui.ui.SymphonyDataManager.trace('epoch: populateEntityTabs');
                    obj.populateEntityTabs(kind, eid);
                    symphonyui.ui.SymphonyDataManager.stepFlush('after populateEntityTabs');
                    symphonyui.ui.SymphonyDataManager.trace('epoch: done');
                case {'sources_folder', 'epoch_groups_folder'}
                    obj.showCard('empty');
                    obj.populateEntityTabsEmpty();
                otherwise
                    obj.showCard('empty');
                    obj.populateEntityTabsEmpty();
            end
        end

        function loadEpochsForBlock(obj, blockId)
            % Lazy-load epoch nodes under the selected epoch block.
            % Only loads if the block node has no children yet.
            try
                selectedNode = obj.tree.SelectedNodes;
                if isempty(selectedNode), return; end
                node = selectedNode(1);
                nd = node.NodeData;
                if ~isstruct(nd) || ~strcmp(nd.kind, 'epoch_block'), return; end
                if ~strcmp(nd.id, blockId), return; end

                % Already has epoch children?
                if ~isempty(node.Children), return; end

                % Fetch epochs on-demand from the C# host. This avoids
                % including all epochs in the main BuildState() DTO,
                % which was O(n) in HDF5 reads and took 3-5 seconds
                % with 800+ epochs in previous epoch groups.
                ic = @obj.iconIfAny;
                epochs = obj.awaitTaskWithResult(obj.host.GetEpochsForBlockAsync(blockId));
                nEpochs = SymphonyAppUtil.getNetCount(epochs);
                for j = 1:nEpochs
                    ep = SymphonyAppUtil.getNetItem(epochs, j);
                    en = uitreenode(node, 'Text', char(ep.DisplayName), ...
                        'Icon', ic('epoch.png'));
                    en.NodeData = struct('kind', 'epoch', 'id', char(ep.Id));
                    try en.ContextMenu = obj.makeEpochContextMenu(en); catch, end
                end

                % Expand the block node to show epochs
                if ~isempty(node.Children)
                    expand(node);
                end
            catch ex
                fprintf(2, 'loadEpochsForBlock error: %s\n', ex.message);
            end
        end

        function showCard(obj, which)
            obj.layoutDetailStack(which);
            symphonyui.ui.SymphonyDataManager.stepFlush('showCard: after layoutDetailStack');
            % No uistack here: layoutDetailStack already shows exactly one card
            % (Visible on/off), and uistack on the epoch card, which holds the
            % uiaxes, wedged the uifigure's view sync so a full drawnow never
            % returned and the preview never rendered (Rig A, 2026-10-08).

            % Adjust vertical splitter: give full space to tabs for
            % non-epoch entities; show waveform preview for epochs.
            try
                if strcmp(which, 'epoch')
                    obj.vSplitter.setFraction(0.55);
                    symphonyui.ui.SymphonyDataManager.stepFlush('showCard: after setFraction');
                    obj.refreshEpochAxesLayout();
                else
                    % Minimize upper panel — all info is in the tabs
                    obj.vSplitter.setFraction(0.01);
                end
            catch
            end
            symphonyui.ui.SymphonyDataManager.stepFlush('showCard: after splitter block');
            % Clear stale table data before drawnow to avoid
            % "Selection indices are out of data boundary" errors.
            try
                if isempty(obj.propTable.Data)
                    obj.propTable.Selection = [];
                end
            catch
            end
            symphonyui.ui.SymphonyDataManager.stepFlush('showCard: after table clear');
            try
                drawnow limitrate;
            catch
            end
            % Scroll the detail panel to the top
            try
                scroll(obj.cardStack, 'top');
            catch
            end
            symphonyui.ui.SymphonyDataManager.stepFlush('showCard: after scroll');
        end

        function fillExperimentCard(obj, dm)
            try
                if isempty(dm)
                    return;
                end
                ex = dm.Experiment;
                if isempty(ex)
                    obj.expPurposeField.Value = '';
                    obj.expStartLabel.Text = '';
                    obj.expEndLabel.Text = '';
                    return;
                end
                obj.expPurposeField.Value = char(ex.Purpose);
                obj.expStartLabel.Text = char(ex.StartedAt.ToString('u'));
                try
                    if isempty(ex.EndedAt)
                        obj.expEndLabel.Text = '';
                    else
                        obj.expEndLabel.Text = char(ex.EndedAt.ToString('u'));
                    end
                catch
                    obj.expEndLabel.Text = '';
                end
            catch
            end

            % Populate the Properties tab from the ExperimentDescription
            obj.fillExperimentProperties();
        end

        function rebuildExperimentDescriptionRows(~)
            % No-op: experiment description fields are now shown
            % exclusively in the lower Properties tab via fillExperimentProperties.
        end

        function onExperimentDescPropertyChanged(obj, propName, newValue)
            % Update the experiment description property value on the
            % MATLAB-side cached description object.
            if ~isempty(obj.experimentDescription)
                descriptors = obj.experimentDescription.getPropertyDescriptors();
                for i = 1:numel(descriptors)
                    if strcmp(descriptors(i).name, propName)
                        descriptors(i).value = newValue;
                        break;
                    end
                end
            end
            % Persist to HDF5 via the persistor's Experiment.AddProperty.
            try
                cper = obj.host.GetPersistor();
                if ~isempty(cper)
                    experiment = cper.Experiment;
                    % Convert MATLAB value to .NET property value
                    netVal = Symphony.Core.Measurement(0, 'unitless');
                    if isnumeric(newValue)
                        netVal = Symphony.Core.Measurement(double(newValue), 'unitless');
                    else
                        netVal = System.String(char(string(newValue)));
                    end
                    experiment.AddProperty(propName, netVal);
                else
                    fprintf(2, 'Note: no open file — experiment property "%s" saved in-memory only.\n', propName);
                end
            catch ex
                fprintf(2, 'Failed to persist experiment property "%s": %s\n', propName, ex.message);
            end
        end

        function fillExperimentProperties(obj)
            % Populate the Properties tab with editable fields from the
            % ExperimentDescription using the dynamic grid (with dropdowns).
            obj.clearPropDynamicGrid();

            if isempty(obj.experimentDescription)
                obj.showPropTable();
                return;
            end

            try
                descriptors = obj.experimentDescription.getPropertyDescriptors();
                visDescs = {};
                for i = 1:numel(descriptors)
                    if ~descriptors(i).isHidden
                        visDescs{end+1} = descriptors(i); %#ok<AGROW>
                    end
                end
                nDesc = numel(visDescs);
                if nDesc == 0
                    obj.showPropTable();
                    return;
                end

                % Switch to dynamic grid
                obj.showPropDynamicGrid();

                % Header rows: Purpose, Start time, End time
                nHeader = 3;
                nRows = nHeader + nDesc;
                obj.propDynamicGrid.RowHeight = repmat({22}, 1, nRows);

                % Get experiment info from data manager
                expPurpose = ''; expStart = ''; expEnd = '';
                try
                    dm = obj.host.GetDataManagerStateAsync().GetAwaiter().GetResult();
                    exp = dm.Experiment;
                    if ~isempty(exp)
                        try expPurpose = char(exp.Purpose); catch, end
                        try expStart = char(exp.StartedAt.ToString('yyyy-MM-dd HH:mm:ss')); catch, end
                        try
                            if ~isempty(exp.EndedAt) && exp.EndedAt.HasValue
                                expEnd = char(exp.EndedAt.Value.ToString('yyyy-MM-dd HH:mm:ss'));
                            end
                        catch, end
                    end
                catch
                end

                % Row 1: Purpose
                e1 = uilabel(obj.propDynamicGrid, 'Text', 'Purpose:', ...
                    'HorizontalAlignment', 'right', 'FontSize', 11);
                e1.Layout.Row = 1; e1.Layout.Column = 1;
                purposeField = uieditfield(obj.propDynamicGrid, 'Value', expPurpose, 'FontSize', 11, ...
                    'ValueChangedFcn', @(s,~) obj.commitExperimentPurpose());
                purposeField.Layout.Row = 1; purposeField.Layout.Column = 2;
                obj.expPurposeField = purposeField;

                % Row 2: Start time
                e2 = uilabel(obj.propDynamicGrid, 'Text', 'Start time:', ...
                    'HorizontalAlignment', 'right', 'FontSize', 11);
                e2.Layout.Row = 2; e2.Layout.Column = 1;
                startLbl = uilabel(obj.propDynamicGrid, 'Text', expStart, 'FontSize', 11);
                startLbl.Layout.Row = 2; startLbl.Layout.Column = 2;

                % Row 3: End time
                e3 = uilabel(obj.propDynamicGrid, 'Text', 'End time:', ...
                    'HorizontalAlignment', 'right', 'FontSize', 11);
                e3.Layout.Row = 3; e3.Layout.Column = 1;
                endLbl = uilabel(obj.propDynamicGrid, 'Text', expEnd, 'FontSize', 11);
                endLbl.Layout.Row = 3; endLbl.Layout.Column = 2;

                controls = {};
                for i = 1:nDesc
                    d = visDescs{i};
                    rowIdx = i + nHeader;

                    lbl = uilabel(obj.propDynamicGrid, ...
                        'Text', [d.displayName ':'], ...
                        'HorizontalAlignment', 'right', 'FontSize', 11);
                    lbl.Layout.Row = rowIdx;
                    lbl.Layout.Column = 1;
                    controls{end+1} = lbl; %#ok<AGROW>

                    % Determine if this property has an enumerated domain
                    hasDomain = false;
                    if ~isempty(d.type) && isa(d.type, 'symphonyui.core.PropertyType') ...
                            && iscell(d.type.domain) && ~isempty(d.type.domain)
                        hasDomain = true;
                        domainItems = d.type.domain;
                        for j = 1:numel(domainItems)
                            if ~ischar(domainItems{j}) && ~isstring(domainItems{j})
                                domainItems{j} = num2str(domainItems{j});
                            end
                        end
                    end

                    valStr = '';
                    if ~isempty(d.value)
                        if isnumeric(d.value)
                            valStr = num2str(d.value);
                        else
                            valStr = char(string(d.value));
                        end
                    end

                    if hasDomain
                        ctrl = uidropdown(obj.propDynamicGrid, ...
                            'Items', domainItems, ...
                            'Value', valStr, ...
                            'FontSize', 11, ...
                            'Enable', SymphonyAppUtil.onOff(~d.isReadOnly), ...
                            'ValueChangedFcn', @(s, e) obj.onExperimentDescPropertyChanged(d.name, s.Value));
                    elseif islogical(d.value)
                        ctrl = uidropdown(obj.propDynamicGrid, ...
                            'Items', {'true', 'false'}, ...
                            'Value', valStr, ...
                            'FontSize', 11, ...
                            'Enable', SymphonyAppUtil.onOff(~d.isReadOnly), ...
                            'ValueChangedFcn', @(s, e) obj.onExperimentDescPropertyChanged(d.name, s.Value));
                    else
                        ctrl = uieditfield(obj.propDynamicGrid, ...
                            'Value', valStr, ...
                            'FontSize', 11, ...
                            'Editable', SymphonyAppUtil.onOff(~d.isReadOnly), ...
                            'ValueChangedFcn', @(s, e) obj.onExperimentDescPropertyChanged(d.name, s.Value));
                    end
                    ctrl.Layout.Row = rowIdx;
                    ctrl.Layout.Column = 2;
                    controls{end+1} = ctrl; %#ok<AGROW>
                end
                obj.propDynamicControls = controls;
            catch ex
                fprintf(2, 'fillExperimentProperties: %s\n', ex.message);
                obj.showPropTable();
            end
        end

        function showPropTable(obj)
            % Show the standard uitable, hide the dynamic grid.
            try
                obj.propTable.Visible = 'on';
                obj.propDynamicGrid.Visible = 'off';
            catch
            end
        end

        function showPropDynamicGrid(obj)
            % Show the dynamic grid, hide the standard uitable.
            try
                obj.propTable.Visible = 'off';
                obj.propDynamicGrid.Visible = 'on';
            catch
            end
        end

        function clearPropDynamicGrid(obj)
            % Remove all children from the dynamic properties grid.
            for k = 1:numel(obj.propDynamicControls)
                try delete(obj.propDynamicControls{k}); catch, end
            end
            obj.propDynamicControls = {};
            % Also delete any children added directly (e.g. by epoch group fill)
            try
                ch = obj.propDynamicGrid.Children;
                for k = 1:numel(ch)
                    delete(ch(k));
                end
                obj.propDynamicGrid.RowHeight = {};
            catch
            end
        end

        function fillSourceDescriptionProperties(obj, sourceId)
            % Populate the Properties tab with editable fields from the
            % source's SourceDescription (e.g. id, description, sex).
            obj.clearPropDynamicGrid();

            % Read the description type and saved property values from HDF5.
            % The old code stores the description type as a resource named
            % 'descriptionType' (serialized via getByteStreamFromArray) and
            % property descriptors as a resource named 'propertyDescriptors'.
            % Property VALUES are stored as .NET properties on the source.
            descId = '';
            propMap = containers.Map();
            try
                cper = obj.host.GetPersistor();
                if ~isempty(cper)
                    allSrcList = symphonyui.ui.AddSourceDialog.collectAllSources(cper.Experiment);
                    for si = 1:numel(allSrcList)
                        csrc = allSrcList{si};
                        try
                            srcUUID = strrep(char(csrc.UUID.ToString()), '-', '');
                        catch
                            continue;
                        end
                        if strcmp(srcUUID, sourceId)
                            % Wrap in a persistent Source to use getResource
                            try
                                pSrc = symphonyui.core.persistent.Source( ...
                                    csrc, symphonyui.core.persistent.EntityFactory());
                                descId = pSrc.getDescriptionType();
                            catch
                            end

                            % Read property values
                            try
                                propEnum = csrc.Properties.GetEnumerator();
                                while propEnum.MoveNext()
                                    kv = propEnum.Current;
                                    key = char(kv.Key);
                                    val = kv.Value;
                                    try
                                        if isa(val, 'System.String')
                                            propMap(key) = char(val);
                                        else
                                            propMap(key) = char(string(val));
                                        end
                                    catch
                                        propMap(key) = char(string(val));
                                    end
                                end
                            catch
                            end
                            break;
                        end
                    end
                end
            catch
            end

            if isempty(descId)
                obj.showPropTable();
                return;
            end

            % Instantiate the description and override defaults with saved values
            try
                ctorFcn = str2func(descId);
                srcDesc = ctorFcn();
                descriptors = srcDesc.getPropertyDescriptors();
                for i = 1:numel(descriptors)
                    if propMap.isKey(descriptors(i).name)
                        descriptors(i).value = propMap(descriptors(i).name);
                    end
                end
            catch ex
                fprintf(2, 'fillSourceDescriptionProperties: could not instantiate "%s": %s\n', descId, ex.message);
                obj.showPropTable();
                return;
            end

            visDescs = {};
            for i = 1:numel(descriptors)
                if ~descriptors(i).isHidden
                    visDescs{end+1} = descriptors(i); %#ok<AGROW>
                end
            end
            nDesc = numel(visDescs);
            if nDesc == 0
                obj.showPropTable();
                return;
            end

            obj.showPropDynamicGrid();

            % Add a "Label" row at the top for the source label
            nRows = nDesc + 1;  % +1 for label row
            obj.propDynamicGrid.RowHeight = repmat({22}, 1, nRows);

            % Row 1: Label (editable)
            srcLabel = '';
            try
                dm = obj.host.GetDataManagerStateAsync().GetAwaiter().GetResult();
                sources = dm.Sources;
                n = SymphonyAppUtil.getNetCount(sources);
                for si = 1:n
                    s = SymphonyAppUtil.getNetItem(sources, si);
                    if strcmp(char(s.Id), sourceId)
                        srcLabel = char(s.Label);
                        break;
                    end
                end
            catch
            end
            lblName = uilabel(obj.propDynamicGrid, 'Text', 'Label:', ...
                'HorizontalAlignment', 'right', 'FontSize', 11);
            lblName.Layout.Row = 1; lblName.Layout.Column = 1;
            capturedSrcId = sourceId;
            lblField = uieditfield(obj.propDynamicGrid, 'Value', srcLabel, ...
                'FontSize', 11, ...
                'ValueChangedFcn', @(s,~) obj.commitSourceLabelFromPropGrid(capturedSrcId, s.Value));
            lblField.Layout.Row = 1; lblField.Layout.Column = 2;

            controls = {lblName, lblField};
            for i = 1:nDesc
                d = visDescs{i};
                rowIdx = i + 1;  % offset by 1 for label row

                lbl = uilabel(obj.propDynamicGrid, ...
                    'Text', [d.displayName ':'], ...
                    'HorizontalAlignment', 'right', 'FontSize', 11);
                lbl.Layout.Row = rowIdx;
                lbl.Layout.Column = 1;
                controls{end+1} = lbl; %#ok<AGROW>

                hasDomain = false;
                isMultiSelect = false;
                if ~isempty(d.type) && isa(d.type, 'symphonyui.core.PropertyType') ...
                        && iscell(d.type.domain) && ~isempty(d.type.domain)
                    hasDomain = true;
                    domainItems = d.type.domain;
                    for j = 1:numel(domainItems)
                        if ~ischar(domainItems{j}) && ~isstring(domainItems{j})
                            domainItems{j} = num2str(domainItems{j});
                        end
                    end
                    % 'cellstr' primitive type means multi-select
                    if strcmp(d.type.primitiveType, 'cellstr')
                        isMultiSelect = true;
                    end
                end

                valStr = '';
                selectedValues = {};
                if ~isempty(d.value)
                    if iscell(d.value)
                        % Multi-select: value is a cell array of strings
                        selectedValues = cellfun(@(x) char(string(x)), d.value, 'UniformOutput', false);
                    elseif isnumeric(d.value)
                        valStr = num2str(d.value);
                    else
                        valStr = char(string(d.value));
                    end
                end

                capturedSourceId = sourceId;
                isMapDomain = ~isempty(d.type) && isa(d.type, 'symphonyui.core.PropertyType') ...
                    && isa(d.type.domain, 'containers.Map');

                if isMultiSelect && hasDomain
                    % Multi-select: show current values as semicolon-separated
                    % text in a button; clicking opens a checkbox dialog.
                    if ~isempty(selectedValues)
                        dispStr = strjoin(selectedValues, '; ');
                    else
                        dispStr = '(click to select)';
                    end
                    capturedDomain = domainItems;
                    capturedSelVals = selectedValues;
                    ctrl = uibutton(obj.propDynamicGrid, ...
                        'Text', dispStr, ...
                        'FontSize', 11, ...
                        'HorizontalAlignment', 'left', ...
                        'Enable', SymphonyAppUtil.onOff(~d.isReadOnly), ...
                        'ButtonPushedFcn', @(s, ~) obj.openMultiSelectDialog( ...
                            s, capturedSourceId, d.name, capturedDomain, capturedSelVals));
                elseif isMapDomain
                    % Hierarchical map domain: show current value as
                    % backslash-separated path; clicking opens a tree dialog.
                    if isempty(valStr)
                        dispStr = '(click to select)';
                    else
                        dispStr = valStr;
                    end
                    capturedMap = d.type.domain;
                    ctrl = uibutton(obj.propDynamicGrid, ...
                        'Text', dispStr, ...
                        'FontSize', 11, ...
                        'HorizontalAlignment', 'left', ...
                        'Enable', SymphonyAppUtil.onOff(~d.isReadOnly), ...
                        'ButtonPushedFcn', @(s, ~) obj.openTreeSelectDialog( ...
                            s, capturedSourceId, d.name, capturedMap, valStr));
                elseif hasDomain
                    % Ensure the current value is in the domain items;
                    % if not, prepend it so the dropdown can display it.
                    if ~any(strcmp(valStr, domainItems))
                        domainItems = [{valStr}, domainItems];
                    end
                    ctrl = uidropdown(obj.propDynamicGrid, ...
                        'Items', domainItems, ...
                        'Value', valStr, ...
                        'FontSize', 11, ...
                        'Enable', SymphonyAppUtil.onOff(~d.isReadOnly), ...
                        'ValueChangedFcn', @(s, e) obj.onSourceDescPropertyChanged(capturedSourceId, d.name, s.Value));
                elseif islogical(d.value)
                    ctrl = uidropdown(obj.propDynamicGrid, ...
                        'Items', {'true', 'false'}, ...
                        'Value', valStr, ...
                        'FontSize', 11, ...
                        'Enable', SymphonyAppUtil.onOff(~d.isReadOnly), ...
                        'ValueChangedFcn', @(s, e) obj.onSourceDescPropertyChanged(capturedSourceId, d.name, s.Value));
                else
                    ctrl = uieditfield(obj.propDynamicGrid, ...
                        'Value', valStr, ...
                        'FontSize', 11, ...
                        'Editable', SymphonyAppUtil.onOff(~d.isReadOnly), ...
                        'ValueChangedFcn', @(s, e) obj.onSourceDescPropertyChanged(capturedSourceId, d.name, s.Value));
                end
                ctrl.Layout.Row = rowIdx;
                ctrl.Layout.Column = 2;
                controls{end+1} = ctrl; %#ok<AGROW>
            end
            obj.propDynamicControls = controls;
        end

        function commitSourceLabelFromPropGrid(obj, sourceId, newLabel)
            % Persist the label to the C# host
            try
                obj.host.RenameSourceAsync(sourceId, newLabel).GetAwaiter().GetResult();
            catch
            end

            % Also persist directly to HDF5 via the persistor
            try
                cper = obj.host.GetPersistor();
                if ~isempty(cper)
                    allSrcList = symphonyui.ui.AddSourceDialog.collectAllSources(cper.Experiment);
                    for si = 1:numel(allSrcList)
                        csrc = allSrcList{si};
                        try
                            srcUUID = strrep(char(csrc.UUID.ToString()), '-', '');
                        catch
                            continue;
                        end
                        if strcmp(srcUUID, sourceId)
                            csrc.Label = newLabel;
                            break;
                        end
                    end
                end
            catch ex
                fprintf(2, 'Failed to persist source label to HDF5: %s\n', ex.message);
            end

            % Update the tree node text by walking the tree
            try
                nodes = obj.tree.Children;
                obj.updateNodeLabel(nodes, sourceId, newLabel);
            catch
            end
        end

        function updateNodeLabel(~, nodes, targetId, newLabel)
            % Walk the tree breadth-first to find and rename the node.
            queue = num2cell(nodes);
            while ~isempty(queue)
                node = queue{1};
                queue(1) = [];
                try
                    nd = node.NodeData;
                    if isstruct(nd) && isfield(nd, 'id') && strcmp(nd.id, targetId)
                        node.Text = newLabel;
                        return;
                    end
                catch
                end
                if ~isempty(node.Children)
                    queue = [queue, num2cell(node.Children)']; %#ok<AGROW>
                end
            end
        end

        function onSourceDescPropertyChanged(obj, sourceId, propName, newValue)
            % Persist the source property to HDF5.
            % newValue may be a char (single value) or cell array (multi-select).
            try
                cper = obj.host.GetPersistor();
                if ~isempty(cper)
                    allSrcList = symphonyui.ui.AddSourceDialog.collectAllSources(cper.Experiment);
                    for si = 1:numel(allSrcList)
                        src = allSrcList{si};
                        if strcmp(strrep(char(src.UUID.ToString()), '-', ''), sourceId)
                            % Wrap in Entity to use propertyValueFromValue
                            factory = symphonyui.core.persistent.EntityFactory();
                            pSrc = symphonyui.core.persistent.Source(src, factory);
                            if iscell(newValue)
                                % Multi-select: serialize as JSON
                                pSrc.setProperty(propName, newValue);
                            else
                                % Coerce the edited text to the type the source
                                % description declared (uint8 cell number, double
                                % location, ...). Symphony 2's grid did this; writing
                                % the raw text made e.g. 'number' an HDF5 string, which
                                % the lab's DataJoint reader cannot parse.
                                value = char(string(newValue));
                                try
                                    d = pSrc.getPropertyDescriptors().findByName(propName);
                                    if isempty(d)
                                        error('no descriptor for %s', propName);
                                    end
                                    pt = char(d.type.primitiveType);
                                    if ~any(strcmp(pt, {'char', 'cellstr', 'string'}))
                                        value = SymphonyAppUtil.coerceValue(value, pt);
                                    end
                                catch coerceEx
                                    fprintf(2, 'Property "%s": could not coerce "%s" to its declared type (%s); storing as text.\n', ...
                                        propName, char(string(newValue)), coerceEx.message);
                                end
                                pSrc.setProperty(propName, value);
                            end
                            break;
                        end
                    end
                end
            catch ex
                fprintf(2, 'Failed to persist source property "%s": %s\n', propName, ex.message);
            end
        end

        function openMultiSelectDialog(obj, btn, sourceId, propName, domainItems, currentSelection)
            %OPENMULTISELECTDIALOG  Checkbox dialog for cellstr multi-select properties.
            %   Selected items are joined with '; ' and displayed on the button.
            try
                f = uifigure('Name', ['Select: ' propName], ...
                    'Position', [200 200 260 min(300, 50 + 24 * numel(domainItems))], ...
                    'WindowStyle', 'modal');
                g = uigridlayout(f, [numel(domainItems) + 1, 1]);
                g.RowHeight = [repmat({22}, 1, numel(domainItems)), {30}];
                g.Padding = [8 8 8 8];
                g.RowSpacing = 2;

                cbs = gobjects(numel(domainItems), 1);
                for ci = 1:numel(domainItems)
                    isChecked = any(strcmp(domainItems{ci}, currentSelection));
                    cbs(ci) = uicheckbox(g, 'Text', domainItems{ci}, ...
                        'Value', isChecked, 'FontSize', 11);
                    cbs(ci).Layout.Row = ci;
                    cbs(ci).Layout.Column = 1;
                end

                okBtn = uibutton(g, 'Text', 'OK', ...
                    'ButtonPushedFcn', @(~,~)onOK());
                okBtn.Layout.Row = numel(domainItems) + 1;
                okBtn.Layout.Column = 1;

                uiwait(f);
            catch
            end

            function onOK()
                sel = {};
                for ki = 1:numel(cbs)
                    if isvalid(cbs(ki)) && cbs(ki).Value
                        sel{end+1} = domainItems{ki}; %#ok<AGROW>
                    end
                end
                if isempty(sel)
                    btn.Text = '(click to select)';
                else
                    btn.Text = strjoin(sel, '; ');
                end
                obj.onSourceDescPropertyChanged(sourceId, propName, sel);
                delete(f);
            end
        end

        function openTreeSelectDialog(obj, btn, sourceId, propName, mapDomain, currentValue)
            %OPENTREESELECTDIALOG  Hierarchical tree dialog for containers.Map domain.
            %   The map keys are top-level categories; values are cell arrays of sub-items.
            %   Selected path is joined with '\' (e.g. 'RGC\ON-parasol').
            try
                keys = mapDomain.keys;
                totalItems = numel(keys);
                for ki = 1:numel(keys)
                    vals = mapDomain(keys{ki});
                    if iscell(vals)
                        totalItems = totalItems + numel(vals);
                    end
                end

                f = uifigure('Name', ['Select: ' propName], ...
                    'Position', [200 200 300 min(400, 60 + 20 * totalItems)], ...
                    'WindowStyle', 'modal');
                g = uigridlayout(f, [2 1]);
                g.RowHeight = {'1x', 30};
                g.Padding = [8 8 8 8];

                tree = uitree(g, 'FontSize', 11);
                tree.Layout.Row = 1;
                tree.Layout.Column = 1;

                % Build tree nodes
                for ki = 1:numel(keys)
                    kn = uitreenode(tree, 'Text', keys{ki});
                    vals = mapDomain(keys{ki});
                    if iscell(vals)
                        for vi = 1:numel(vals)
                            if isa(vals{vi}, 'containers.Map')
                                % Nested map — add sub-keys
                                subKeys = vals{vi}.keys;
                                for ski = 1:numel(subKeys)
                                    uitreenode(kn, 'Text', subKeys{ski});
                                end
                            else
                                uitreenode(kn, 'Text', char(string(vals{vi})));
                            end
                        end
                    end
                end

                % Expand all and try to select current value
                expand(tree, 'all');
                if ~isempty(currentValue)
                    pathParts = strsplit(currentValue, '\');
                    try
                        selNode = [];
                        nodes = tree.Children;
                        for pi = 1:numel(pathParts)
                            for ni = 1:numel(nodes)
                                if strcmp(nodes(ni).Text, pathParts{pi})
                                    selNode = nodes(ni);
                                    nodes = selNode.Children;
                                    break;
                                end
                            end
                        end
                        if ~isempty(selNode)
                            tree.SelectedNodes = selNode;
                        end
                    catch
                    end
                end

                okBtn = uibutton(g, 'Text', 'OK', ...
                    'ButtonPushedFcn', @(~,~)onOK());
                okBtn.Layout.Row = 2;
                okBtn.Layout.Column = 1;

                uiwait(f);
            catch
            end

            function onOK()
                % Build path from selected node up to root
                selPath = '';
                try
                    selNodes = tree.SelectedNodes;
                    if ~isempty(selNodes)
                        node = selNodes(1);
                        parts = {};
                        while ~isempty(node) && ~isa(node.Parent, 'matlab.ui.container.Tree')
                            parts = [{node.Text}, parts]; %#ok<AGROW>
                            node = node.Parent;
                        end
                        if ~isempty(node) && isa(node.Parent, 'matlab.ui.container.Tree')
                            parts = [{node.Text}, parts];
                        end
                        selPath = strjoin(parts, '\');
                    end
                catch
                end
                if isempty(selPath)
                    btn.Text = '(click to select)';
                else
                    btn.Text = selPath;
                end
                obj.onSourceDescPropertyChanged(sourceId, propName, selPath);
                delete(f);
            end
        end

        function fillSourceCard(obj, dm, sourceId)
            if isempty(dm)
                return;
            end
            sid = char(string(sourceId));
            n = SymphonyAppUtil.getNetCount(dm.Sources);
            for i = 1:n
                s = SymphonyAppUtil.getNetItem(dm.Sources, i);
                if strcmp(char(string(s.Id)), sid)
                    obj.srcLabelField.Value = char(s.Label);
                    return;
                end
            end
        end

        function fillEpochGroupCard(obj, dm, groupId)
            if isempty(dm)
                return;
            end
            gid = char(string(groupId));
            n = SymphonyAppUtil.getNetCount(dm.EpochGroups);
            items = {};
            vals = {};
            ns = SymphonyAppUtil.getNetCount(dm.Sources);
            for j = 1:ns
                s = SymphonyAppUtil.getNetItem(dm.Sources, j);
                items{end + 1} = char(s.Label); %#ok<AGROW>
                vals{end + 1} = char(s.Id); %#ok<AGROW>
            end
            if isempty(items)
                items = {'(No sources)'};
                vals = {''};
            end
            obj.grpSourceDropDown.Items = items;
            obj.grpSourceDropDown.ItemsData = vals;

            for i = 1:n
                g = SymphonyAppUtil.getNetItem(dm.EpochGroups, i);
                if strcmp(char(string(g.Id)), gid)
                    obj.grpLabelField.Value = char(g.Label);
                    obj.grpStartLabel.Text = char(g.StartedAt.ToString('u'));
                    try
                        if isempty(g.EndedAt)
                            obj.grpEndLabel.Text = '';
                        else
                            obj.grpEndLabel.Text = char(g.EndedAt.ToString('u'));
                        end
                    catch
                        obj.grpEndLabel.Text = '';
                    end
                    sid = g.SourceId;
                    if isempty(sid)
                        obj.grpSourceDropDown.Value = vals{1};
                    else
                        match = char(sid);
                        for k = 1:numel(vals)
                            if strcmp(vals{k}, match)
                                obj.grpSourceDropDown.Value = vals{k};
                                break;
                            end
                        end
                    end

                    return;
                end
            end
        end

        function fillEpochGroupDescriptionProperties(obj, groupId)
            %FILLEPOCHGROUPDESCRIPTIONPROPERTIES  Display epoch group
            %   description properties with appropriate controls (dropdowns,
            %   multi-select, edit fields) in the grpDescGrid.
            % Switch to the dynamic grid in the Properties tab
            obj.showPropDynamicGrid();

            % Clear existing controls
            obj.clearPropDynamicGrid();

            % Read description ID and properties from HDF5
            descId = '';
            savedProps = containers.Map();
            try
                cper = obj.host.GetPersistor();
                if isempty(cper)
                    return;
                end

                % Find the epoch group in the persistor
                pEG = obj.findPersistentEpochGroup(cper, groupId);
                if isempty(pEG), return; end

                % Read ALL properties via PropertiesList() for MATLAB interop
                try
                    propList = pEG.PropertiesList();
                    nProps = propList.Count;
                    for pi = 0:nProps-1
                        kvp = propList.Item(pi);
                        pKey = char(kvp.Key);
                        pVal = char(string(kvp.Value));
                        if strcmp(pKey, '__epochGroupDescriptionId')
                            descId = pVal;
                        elseif ~startsWith(pKey, '__')
                            savedProps(pKey) = pVal;
                        end
                    end
                catch
                end
            catch outerEx
                fprintf(2, '  outer error: %s\n', outerEx.message);
            end

            if isempty(descId) && savedProps.Count == 0
                return;
            end

            % Try to instantiate the description to get property types
            descInst = [];
            if ~isempty(descId)
                try
                    descInst = feval(str2func(descId));
                catch
                end
            end

            % Build the property list
            if ~isempty(descInst)
                descList = descInst.getPropertyDescriptors();
            else
                descList = [];
            end

            if ~isempty(descList)
                nDesc = numel(descList);

                % Add header rows: Label, Start time, End time, Source
                nHeader = 4;
                nRows = nHeader + nDesc;
                obj.propDynamicGrid.RowHeight = repmat({22}, 1, nRows);

                % Read epoch group info from data manager
                grpLabel = ''; grpStart = ''; grpEnd = ''; grpSource = '';
                try
                    dm = obj.host.GetDataManagerStateAsync().GetAwaiter().GetResult();
                    egs = dm.EpochGroups;
                    nEg = SymphonyAppUtil.getNetCount(egs);
                    for gi = 1:nEg
                        eg = SymphonyAppUtil.getNetItem(egs, gi);
                        if strcmp(char(eg.Id), groupId)
                            grpLabel = char(eg.Label);
                            try grpStart = char(eg.StartedAt.ToString('yyyy-MM-dd HH:mm:ss')); catch, end
                            try
                                if ~isempty(eg.EndedAt) && eg.EndedAt.HasValue
                                    grpEnd = char(eg.EndedAt.Value.ToString('yyyy-MM-dd HH:mm:ss'));
                                end
                            catch, end
                            try
                                if ~isempty(eg.SourceId)
                                    sid = char(eg.SourceId);
                                    srcs = dm.Sources;
                                    nSrc = SymphonyAppUtil.getNetCount(srcs);
                                    for si = 1:nSrc
                                        s = SymphonyAppUtil.getNetItem(srcs, si);
                                        if strcmp(char(s.Id), sid)
                                            grpSource = char(s.Label);
                                            break;
                                        end
                                    end
                                end
                            catch, end
                            break;
                        end
                    end
                catch
                end

                % Row 1: Label
                h1 = uilabel(obj.propDynamicGrid, 'Text', 'Label:', ...
                    'HorizontalAlignment', 'right', 'FontSize', 11);
                h1.Layout.Row = 1; h1.Layout.Column = 1;
                capturedGid = groupId;
                egLblField = uieditfield(obj.propDynamicGrid, 'Value', grpLabel, 'FontSize', 11, ...
                    'ValueChangedFcn', @(s,~) obj.commitEpochGroupLabelFromPropGrid(capturedGid, s.Value));
                egLblField.Layout.Row = 1; egLblField.Layout.Column = 2;

                % Row 2: Start time
                h2 = uilabel(obj.propDynamicGrid, 'Text', 'Start time:', ...
                    'HorizontalAlignment', 'right', 'FontSize', 11);
                h2.Layout.Row = 2; h2.Layout.Column = 1;
                startLbl = uilabel(obj.propDynamicGrid, 'Text', grpStart, 'FontSize', 11);
                startLbl.Layout.Row = 2; startLbl.Layout.Column = 2;

                % Row 3: End time
                h3 = uilabel(obj.propDynamicGrid, 'Text', 'End time:', ...
                    'HorizontalAlignment', 'right', 'FontSize', 11);
                h3.Layout.Row = 3; h3.Layout.Column = 1;
                endLbl = uilabel(obj.propDynamicGrid, 'Text', grpEnd, 'FontSize', 11);
                endLbl.Layout.Row = 3; endLbl.Layout.Column = 2;

                % Row 4: Source
                h4 = uilabel(obj.propDynamicGrid, 'Text', 'Source:', ...
                    'HorizontalAlignment', 'right', 'FontSize', 11);
                h4.Layout.Row = 4; h4.Layout.Column = 1;
                srcLbl = uilabel(obj.propDynamicGrid, 'Text', grpSource, 'FontSize', 11);
                srcLbl.Layout.Row = 4; srcLbl.Layout.Column = 2;

                for i = 1:nDesc
                    d = descList(i);
                    rowIdx = i + nHeader;
                    lbl = uilabel(obj.propDynamicGrid, 'Text', [appbox.humanize(d.name) ':'], ...
                        'HorizontalAlignment', 'right', 'FontSize', 11);
                    lbl.Layout.Row = rowIdx;
                    lbl.Layout.Column = 1;

                    % Get saved value
                    valStr = '';
                    if savedProps.isKey(d.name)
                        valStr = savedProps(d.name);
                    end

                    % Determine control type from PropertyType
                    hasDomain = false;
                    isMultiSelect = false;
                    isMapDomain = false;
                    domainItems = {};
                    if ~isempty(d.type) && isa(d.type, 'symphonyui.core.PropertyType')
                        if isa(d.type.domain, 'containers.Map')
                            isMapDomain = true;
                        elseif iscell(d.type.domain) && ~isempty(d.type.domain)
                            hasDomain = true;
                            domainItems = cellfun(@(x)char(string(x)), d.type.domain, 'UniformOutput', false);
                        end
                        if strcmp(d.type.primitiveType, 'cellstr')
                            isMultiSelect = true;
                        end
                    end

                    capturedGroupId = groupId;
                    capturedName = d.name;

                    if isMultiSelect && hasDomain
                        % Multi-select checkbox button
                        selectedValues = {};
                        if ~isempty(valStr)
                            selectedValues = strsplit(valStr, ';');
                            selectedValues = strtrim(selectedValues);
                            selectedValues = selectedValues(~cellfun('isempty', selectedValues));
                        end
                        if isempty(selectedValues)
                            dispStr = '(click to select)';
                        else
                            dispStr = strjoin(selectedValues, '; ');
                        end
                        ctrl = uibutton(obj.propDynamicGrid, ...
                            'Text', dispStr, 'FontSize', 11, ...
                            'HorizontalAlignment', 'left', ...
                            'ButtonPushedFcn', @(s, ~) obj.openEpochGroupMultiSelectDialog( ...
                                s, capturedGroupId, capturedName, domainItems, selectedValues));
                    elseif isMapDomain
                        % Hierarchical tree button
                        if isempty(valStr)
                            dispStr = '(click to select)';
                        else
                            dispStr = valStr;
                        end
                        ctrl = uibutton(obj.propDynamicGrid, ...
                            'Text', dispStr, 'FontSize', 11, ...
                            'HorizontalAlignment', 'left', ...
                            'ButtonPushedFcn', @(s, ~) obj.openEpochGroupTreeSelectDialog( ...
                                s, capturedGroupId, capturedName, d.type.domain, valStr));
                    elseif hasDomain
                        % Single-select dropdown
                        if ~any(strcmp(valStr, domainItems))
                            domainItems = [{valStr}, domainItems];
                        end
                        ctrl = uidropdown(obj.propDynamicGrid, ...
                            'Items', domainItems, 'Value', valStr, ...
                            'FontSize', 11, ...
                            'ValueChangedFcn', @(s, ~) obj.onEpochGroupDescPropertyChanged( ...
                                capturedGroupId, capturedName, s.Value));
                    else
                        % Plain edit field
                        ctrl = uieditfield(obj.propDynamicGrid, ...
                            'Value', valStr, 'FontSize', 11, ...
                            'ValueChangedFcn', @(s, ~) obj.onEpochGroupDescPropertyChanged( ...
                                capturedGroupId, capturedName, s.Value));
                    end
                    ctrl.Layout.Row = rowIdx;
                    ctrl.Layout.Column = 2;
                end
            elseif savedProps.Count > 0
                % No description instance — show as plain edit fields
                keys = savedProps.keys;
                obj.propDynamicGrid.RowHeight = repmat({22}, 1, numel(keys));
                for i = 1:numel(keys)
                    lbl = uilabel(obj.propDynamicGrid, 'Text', [appbox.humanize(keys{i}) ':'], ...
                        'HorizontalAlignment', 'right', 'FontSize', 11);
                    lbl.Layout.Row = i;
                    lbl.Layout.Column = 1;
                    ctrl = uieditfield(obj.propDynamicGrid, ...
                        'Value', savedProps(keys{i}), 'FontSize', 11, ...
                        'ValueChangedFcn', @(s, ~) obj.onEpochGroupDescPropertyChanged( ...
                            groupId, keys{i}, s.Value));
                    ctrl.Layout.Row = i;
                    ctrl.Layout.Column = 2;
                end
            end
        end

        function pEG = findPersistentEpochGroup(obj, cper, groupId)
            %FINDPERSISTENTEPOCHGROUP  Find an epoch group in the persistor by ID.
            pEG = [];
            gidClean = lower(strrep(groupId, '-', ''));
            try
                % Try current epoch group first
                eg = cper.CurrentEpochGroup;
                if ~isempty(eg)
                    egUuid = lower(strrep(char(eg.UUID.ToString()), '-', ''));
                    if strcmp(egUuid, gidClean)
                        pEG = eg;
                        return;
                    end
                end
            catch curEx
                fprintf(2, '    CurrentEpochGroup error: %s\n', curEx.message);
            end
            % Walk experiment epoch groups
            try
                egList = cper.Experiment.EpochGroupsList();
                nEg = egList.Count;
                for i = 0:nEg-1
                    eg = egList.Item(i);
                    egUuid = lower(strrep(char(eg.UUID.ToString()), '-', ''));
                    if strcmp(egUuid, gidClean)
                        pEG = eg;
                        return;
                    end
                end
            catch
            end
        end

        function commitEpochGroupLabelFromPropGrid(obj, groupId, newLabel)
            % Update HDF5 directly
            try
                cper = obj.host.GetPersistor();
                pEG = obj.findPersistentEpochGroup(cper, groupId);
                if ~isempty(pEG)
                    pEG.Label = newLabel;
                end
            catch ex
                fprintf(2, 'Failed to update epoch group label in HDF5: %s\n', ex.message);
            end

            % Try C# host too
            try
                obj.host.RenameEpochGroupAsync(groupId, newLabel).GetAwaiter().GetResult();
            catch
            end

            % Update the tree node text directly
            try
                existingIds = obj.collectExistingNodeIds(obj.tree);
                if existingIds.isKey(groupId)
                    node = existingIds(groupId);
                    % Preserve the source label in parentheses if present
                    oldText = node.Text;
                    parenIdx = strfind(oldText, ' (');
                    if ~isempty(parenIdx)
                        node.Text = [newLabel, oldText(parenIdx(1):end)];
                    else
                        node.Text = newLabel;
                    end
                end
            catch
            end
        end

        function onEpochGroupDescPropertyChanged(obj, groupId, propName, newValue)
            %ONEPOCHGROUPDESCPROPERTYCHANGED  Persist a changed epoch group property to HDF5.
            try
                cper = obj.host.GetPersistor();
                if isempty(cper), return; end
                pEG = obj.findPersistentEpochGroup(cper, groupId);
                if isempty(pEG), return; end

                % Go through the MATLAB entity wrapper so the value is coerced to
                % the type the epoch group description declared (Symphony 2
                % behaviour) instead of always being stored as text.
                factory = symphonyui.core.persistent.EntityFactory();
                pGroup = symphonyui.core.persistent.EpochGroup(pEG, factory);
                if iscell(newValue)
                    value = newValue;
                else
                    value = char(string(newValue));
                    try
                        d = pGroup.getPropertyDescriptors().findByName(propName);
                        if isempty(d)
                            error('no descriptor for %s', propName);
                        end
                        pt = char(d.type.primitiveType);
                        if ~any(strcmp(pt, {'char', 'cellstr', 'string'}))
                            value = SymphonyAppUtil.coerceValue(value, pt);
                        end
                    catch coerceEx
                        fprintf(2, 'Property "%s": could not coerce "%s" to its declared type (%s); storing as text.\n', ...
                            propName, char(string(newValue)), coerceEx.message);
                    end
                end
                pGroup.setProperty(propName, value);
            catch ex
                fprintf(2, 'Failed to persist epoch group property "%s": %s\n', propName, ex.message);
            end
        end

        function openEpochGroupMultiSelectDialog(obj, btn, groupId, propName, domainItems, currentSelection)
            %OPENEPOCHGROUPMULTISELECTDIALOG  Multi-select dialog for epoch group properties.
            try
                f = uifigure('Name', ['Select: ' propName], ...
                    'Position', [200 200 260 min(300, 50 + 24 * numel(domainItems))], ...
                    'WindowStyle', 'modal');
                g = uigridlayout(f, [numel(domainItems) + 1, 1]);
                g.RowHeight = [repmat({22}, 1, numel(domainItems)), {30}];
                g.Padding = [8 8 8 8];
                g.RowSpacing = 2;

                cbs = gobjects(numel(domainItems), 1);
                for ci = 1:numel(domainItems)
                    isChecked = any(strcmp(domainItems{ci}, currentSelection));
                    cbs(ci) = uicheckbox(g, 'Text', domainItems{ci}, ...
                        'Value', isChecked, 'FontSize', 11);
                    cbs(ci).Layout.Row = ci;
                    cbs(ci).Layout.Column = 1;
                end

                okBtn = uibutton(g, 'Text', 'OK', ...
                    'ButtonPushedFcn', @(~,~)onOK());
                okBtn.Layout.Row = numel(domainItems) + 1;
                okBtn.Layout.Column = 1;

                uiwait(f);
            catch
            end

            function onOK()
                sel = {};
                for ki = 1:numel(cbs)
                    if isvalid(cbs(ki)) && cbs(ki).Value
                        sel{end+1} = domainItems{ki}; %#ok<AGROW>
                    end
                end
                if isempty(sel)
                    btn.Text = '(click to select)';
                else
                    btn.Text = strjoin(sel, '; ');
                end
                obj.onEpochGroupDescPropertyChanged(groupId, propName, sel);
                delete(f);
            end
        end

        function openEpochGroupTreeSelectDialog(obj, btn, groupId, propName, mapDomain, currentValue)
            %OPENEPOCHGROUPTREESELECTDIALOG  Tree dialog for epoch group properties.
            try
                keys = mapDomain.keys;
                totalItems = numel(keys);
                for ki = 1:numel(keys)
                    vals = mapDomain(keys{ki});
                    if iscell(vals)
                        totalItems = totalItems + numel(vals);
                    end
                end

                f = uifigure('Name', ['Select: ' propName], ...
                    'Position', [200 200 300 min(400, 60 + 20 * totalItems)], ...
                    'WindowStyle', 'modal');
                g = uigridlayout(f, [2 1]);
                g.RowHeight = {'1x', 30};
                g.Padding = [8 8 8 8];

                tree = uitree(g, 'FontSize', 11);
                tree.Layout.Row = 1; tree.Layout.Column = 1;

                for ki = 1:numel(keys)
                    kn = uitreenode(tree, 'Text', keys{ki});
                    vals = mapDomain(keys{ki});
                    if iscell(vals)
                        for vi = 1:numel(vals)
                            if isa(vals{vi}, 'containers.Map')
                                subKeys = vals{vi}.keys;
                                for ski = 1:numel(subKeys)
                                    uitreenode(kn, 'Text', subKeys{ski});
                                end
                            else
                                uitreenode(kn, 'Text', char(string(vals{vi})));
                            end
                        end
                    end
                end

                expand(tree, 'all');

                okBtn = uibutton(g, 'Text', 'OK', ...
                    'ButtonPushedFcn', @(~,~)onOK());
                okBtn.Layout.Row = 2; okBtn.Layout.Column = 1;

                uiwait(f);
            catch
            end

            function onOK()
                selPath = '';
                try
                    selNodes = tree.SelectedNodes;
                    if ~isempty(selNodes)
                        node = selNodes(1);
                        parts = {};
                        while ~isempty(node) && ~isa(node.Parent, 'matlab.ui.container.Tree')
                            parts = [{node.Text}, parts]; %#ok<AGROW>
                            node = node.Parent;
                        end
                        if ~isempty(node) && isa(node.Parent, 'matlab.ui.container.Tree')
                            parts = [{node.Text}, parts];
                        end
                        selPath = strjoin(parts, '\');
                    end
                catch
                end
                if isempty(selPath)
                    btn.Text = '(click to select)';
                else
                    btn.Text = selPath;
                end
                obj.onEpochGroupDescPropertyChanged(groupId, propName, selPath);
                delete(f);
            end
        end

        function fillEpochBlockCard(obj, dm, blockId)
            if isempty(dm)
                return;
            end
            bid = char(string(blockId));
            n = SymphonyAppUtil.getNetCount(dm.EpochBlocks);
            for i = 1:n
                b = SymphonyAppUtil.getNetItem(dm.EpochBlocks, i);
                if strcmp(char(string(b.Id)), bid)
                    obj.blkProtocolLabel.Text = char(b.ProtocolId);
                    obj.blkTimesLabel.Text = 'Start/end times are stored in the HDF epoch block.';
                    obj.parametersTable.Data = {'ProtocolId', char(b.ProtocolId); 'DisplayName', char(b.DisplayName)};
                    return;
                end
            end
        end

        function fillEpochCard(obj, dm, epochId)
            if isempty(obj.epochAxes) || ~isvalid(obj.epochAxes)
                return;
            end
            obj.lastEpochPreview = [];
            cla(obj.epochAxes);
            obj.epochAxes.Visible = 'on';
            try
                obj.epochResponseDropDown.Enable = 'off';
            catch
            end
            if isempty(dm)
                title(obj.epochAxes, 'No document loaded.', 'FontSize', 12);
                obj.epochAxesAddCenterPlaceholder('Open or create a data file to use the waveform preview.');
                obj.refreshEpochAxesLayout();
                return;
            end
            eid = char(string(epochId));
            try
                symphonyui.ui.SymphonyDataManager.trace('fillEpochCard: GetEpochDataPreviewAsync');
                prev = obj.awaitTaskWithResult(obj.host.GetEpochDataPreviewAsync(eid));
                symphonyui.ui.SymphonyDataManager.trace('fillEpochCard: preview received');
                if isempty(prev)
                    title(obj.epochAxes, 'Preview unavailable (empty host result).', 'FontSize', 12);
                    obj.epochAxesAddCenterPlaceholder('Host did not return preview data.');
                    obj.refreshEpochAxesLayout();
                    return;
                end
                obj.lastEpochPreview = prev;
                nt = SymphonyAppUtil.getNetCount(prev.Traces);
                diag = obj.readPreviewDiagnostics(prev);
                if nt == 0
                    t1 = 'No waveform samples in this epoch.';
                    if ~isempty(diag)
                        title(obj.epochAxes, sprintf('%s\n%s', t1, obj.clipEpochDiag(diag)), 'Interpreter', 'none', 'FontSize', 11);
                    else
                        title(obj.epochAxes, sprintf('%s\n%s', t1, ...
                            'If you expect data, confirm this file has recorded responses/stimuli for this epoch.'), 'FontSize', 12);
                    end
                    obj.epochAxesAddCenterPlaceholder('No traces to plot — see title above for details.');
                    if ~isempty(prev.XLabel)
                        obj.epochAxes.XLabel.String = char(prev.XLabel);
                    end
                    if ~isempty(prev.YLabel)
                        obj.epochAxes.YLabel.String = char(prev.YLabel);
                    end
                    grid(obj.epochAxes, 'on');
                    obj.configureEpochResponseDropdown(prev, true);
                    obj.refreshEpochAxesLayout();
                    drawnow limitrate;
                    return;
                end
                symphonyui.ui.SymphonyDataManager.trace('fillEpochCard: configure dropdown');
                obj.configureEpochResponseDropdown(prev, false);
                symphonyui.ui.SymphonyDataManager.trace('fillEpochCard: plot traces');
                obj.plotEpochTracesFromPreview(prev);
                symphonyui.ui.SymphonyDataManager.trace('fillEpochCard: plotted');
            catch ex
                title(obj.epochAxes, sprintf('%s\n%s', 'Could not load waveforms', char(ex.message)), 'FontSize', 11);
                obj.epochAxesAddCenterPlaceholder('Preview failed — see title for the error.');
                try
                    obj.epochResponseDropDown.Enable = 'off';
                catch
                end
            end
            symphonyui.ui.SymphonyDataManager.trace('fillEpochCard: refreshEpochAxesLayout');
            obj.refreshEpochAxesLayout();
            symphonyui.ui.SymphonyDataManager.trace('fillEpochCard: drawnow');
            drawnow limitrate;   % a full drawnow never returned in the live app (2026-10-08)
            symphonyui.ui.SymphonyDataManager.trace('fillEpochCard: end');
        end

        function configureEpochResponseDropdown(obj, prev, emptyTraces)
            if isempty(obj.epochResponseDropDown) || ~isvalid(obj.epochResponseDropDown)
                return;
            end
            if nargin < 3
                emptyTraces = false;
            end
            cb = obj.epochResponseDropDown.ValueChangedFcn;
            obj.epochResponseDropDown.ValueChangedFcn = [];
            try
                if emptyTraces || isempty(prev)
                    obj.epochResponseDropDown.Items = {'All traces'};
                    obj.epochResponseDropDown.Value = 'All traces';
                    obj.epochResponseDropDown.Enable = 'off';
                else
                    devs = obj.extractResponseDevicesFromPreview(prev);
                    items = [{'All traces'}, devs{:}];
                    obj.epochResponseDropDown.Items = items;
                    pick = obj.pickDefaultAmpDevice(devs);
                    if isempty(pick)
                        obj.epochResponseDropDown.Value = 'All traces';
                    else
                        obj.epochResponseDropDown.Value = pick;
                    end
                    if ~any(strcmp(obj.epochResponseDropDown.Items, obj.epochResponseDropDown.Value))
                        obj.epochResponseDropDown.Value = obj.epochResponseDropDown.Items{1};
                    end
                    obj.epochResponseDropDown.Enable = 'on';
                end
            catch
                obj.epochResponseDropDown.Items = {'All traces'};
                obj.epochResponseDropDown.Value = 'All traces';
                obj.epochResponseDropDown.Enable = 'off';
            end
            obj.epochResponseDropDown.ValueChangedFcn = cb;
        end

        function onEpochResponseDeviceChanged(obj)
            if isempty(obj.lastEpochPreview)
                return;
            end
            try
                obj.plotEpochTracesFromPreview(obj.lastEpochPreview);
                obj.refreshEpochAxesLayout();
                drawnow limitrate;
            catch
            end
        end

        function plotEpochTracesFromPreview(obj, prev)
            if isempty(obj.epochAxes) || ~isvalid(obj.epochAxes) || isempty(prev)
                return;
            end
            cla(obj.epochAxes);
            obj.epochAxes.Visible = 'on';
            sel = 'All traces';
            try
                if ~isempty(obj.epochResponseDropDown) && isvalid(obj.epochResponseDropDown)
                    sel = char(string(obj.epochResponseDropDown.Value));
                end
            catch
            end
            nt = SymphonyAppUtil.getNetCount(prev.Traces);
            diag = obj.readPreviewDiagnostics(prev);
            hold(obj.epochAxes, 'on');
            plotted = 0;
            xr = [Inf, -Inf];
            yr = [Inf, -Inf];
            for i = 1:nt
                tr = SymphonyAppUtil.getNetItem(prev.Traces, i);
                nm = char(string(tr.Name));
                if ~obj.traceMatchesDeviceSelection(nm, sel)
                    continue;
                end
                x = SymphonyAppUtil.netDoubleVector(tr.X);
                y = SymphonyAppUtil.netDoubleVector(tr.Y);
                x = x(:)';
                y = y(:)';
                n = min(numel(x), numel(y));
                symphonyui.ui.SymphonyDataManager.trace(sprintf('plot: trace [%s] %d samples, x %g..%g, y %g..%g', ...
                    nm, n, min([x NaN]), max([x NaN]), min([y NaN]), max([y NaN])));
                if n < 1
                    continue;
                end
                x = x(1:n);
                y = y(1:n);
                plot(obj.epochAxes, x, y, 'DisplayName', nm, 'LineWidth', 0.9);
                plotted = plotted + 1;
                xr = [min([xr(1), x]), max([xr(2), x])];
                yr = [min([yr(1), y]), max([yr(2), y])];
            end
            hold(obj.epochAxes, 'off');
            % Set the limits explicitly. In the running app the uiaxes'
            % automatic limit update never ran (limits stayed [0 1] with the
            % trace outside the view, Rig A 2026-10-08), so do not rely on it.
            if plotted > 0 && all(isfinite([xr yr]))
                if xr(2) <= xr(1), xr(2) = xr(1) + 1; end
                pad = 0.05 * (yr(2) - yr(1));
                if pad <= 0, pad = max(1, abs(yr(1)) * 0.01); end
                obj.epochAxes.XLim = xr;
                obj.epochAxes.YLim = [yr(1) - pad, yr(2) + pad];
            end
            if plotted == 0
                title(obj.epochAxes, 'No data for this selection', 'FontSize', 12);
                obj.epochAxesAddCenterPlaceholder('Pick another device or choose All traces.');
                if ~isempty(prev.XLabel)
                    obj.epochAxes.XLabel.String = char(prev.XLabel);
                end
                if ~isempty(prev.YLabel)
                    obj.epochAxes.YLabel.String = char(prev.YLabel);
                end
                grid(obj.epochAxes, 'on');
                return;
            end
            try
                legend(obj.epochAxes, 'Location', 'best');
            catch
            end
            if ~isempty(prev.XLabel)
                obj.epochAxes.XLabel.String = char(prev.XLabel);
            end
            if ~isempty(prev.YLabel)
                obj.epochAxes.YLabel.String = char(prev.YLabel);
            end
            if ~isempty(diag)
                title(obj.epochAxes, sprintf('%s\n%s', 'Epoch waveforms', obj.clipEpochDiag(diag)), 'Interpreter', 'none', 'FontSize', 11);
            else
                title(obj.epochAxes, 'Epoch waveforms', 'FontSize', 12);
            end
            grid(obj.epochAxes, 'on');
        end

        function tf = traceMatchesDeviceSelection(obj, traceName, selection)
            tf = false;
            if strcmp(selection, 'All traces')
                tf = true;
                return;
            end
            rp = obj.responseTraceNamePrefix();
            if startsWith(traceName, rp)
                dev = strtrim(extractAfter(traceName, rp));
                tf = strcmp(dev, selection);
                return;
            end
            % Stimuli / other traces only when showing all
            tf = false;
        end

        function p = responseTraceNamePrefix(~)
            % Must match C# PreviewTraceDto name: "Response · {deviceName}" (U+00B7 middle dot).
            p = ['Response ' char(183) ' '];
        end

        function devices = extractResponseDevicesFromPreview(obj, prev)
            devices = {};
            nt = SymphonyAppUtil.getNetCount(prev.Traces);
            rp = obj.responseTraceNamePrefix();
            for i = 1:nt
                tr = SymphonyAppUtil.getNetItem(prev.Traces, i);
                nm = char(string(tr.Name));
                if startsWith(nm, rp)
                    dev = strtrim(extractAfter(nm, rp));
                    if ~isempty(dev) && ~ismember(dev, devices)
                        devices{end + 1} = dev; %#ok<AGROW>
                    end
                end
            end
            devices = obj.sortResponseDevicesForDropdown(devices);
        end

        function out = sortResponseDevicesForDropdown(obj, devices)
            if isempty(devices)
                out = devices;
                return;
            end
            amps = {};
            ampNums = [];
            other = {};
            for i = 1:numel(devices)
                d = devices{i};
                % Allow optional space(s) between "Amp" and the index, e.g. "Amp1" or "Amp 2".
                tk = regexp(d, '^Amp\s*(\d+)$', 'tokens', 'once');
                if ~isempty(tk)
                    amps{end + 1} = d; %#ok<AGROW>
                    ampNums(end + 1) = str2double(tk{1}); %#ok<AGROW>
                else
                    other{end + 1} = d; %#ok<AGROW>
                end
            end
            if ~isempty(ampNums)
                [~, ord] = sort(ampNums);
                amps = amps(ord);
            end
            other = sort(other);
            out = [amps, other];
        end

        function pick = pickDefaultAmpDevice(~, devices)
            pick = '';
            bestNum = inf;
            for i = 1:numel(devices)
                tk = regexp(devices{i}, '^Amp\s*(\d+)$', 'tokens', 'once');
                if ~isempty(tk)
                    n = str2double(tk{1});
                    if n < bestNum
                        bestNum = n;
                        pick = devices{i};
                    end
                end
            end
        end

        function s = epochDefaultTitleText(~)
            s = sprintf('%s\n%s', 'Epoch waveform preview', ...
                'HDF responses & stimuli — open a file and select an epoch in the tree.');
        end

        function epochAxesAddCenterPlaceholder(obj, msg)
            % Gray centered text so the axes area is never an empty white box.
            if isempty(obj.epochAxes) || ~isvalid(obj.epochAxes)
                return;
            end
            if nargin < 2 || isempty(msg)
                msg = '—';
            end
            text(obj.epochAxes, 0.5, 0.52, char(string(msg)), ...
                'Units', 'normalized', ...
                'HorizontalAlignment', 'center', ...
                'VerticalAlignment', 'middle', ...
                'FontSize', 12, ...
                'Color', [0.15 0.15 0.15], ...
                'PickableParts', 'none');
        end

        function s = readPreviewDiagnostics(~, prev)
            s = '';
            try
                if isempty(prev)
                    return;
                end
                raw = prev.Diagnostics;
                if isempty(raw)
                    return;
                end
                s = char(string(raw));
            catch
            end
        end

        function t = clipEpochDiag(~, txt, maxLines)
            if nargin < 3
                maxLines = 18;
            end
            if isempty(txt)
                t = '';
                return;
            end
            lines = splitlines(txt);
            if numel(lines) > maxLines
                lines = lines(1:maxLines);
                lines{end + 1} = '... (truncated)';
            end
            t = strjoin(lines, newline);
        end

        function commitExperimentPurpose(obj)
            try
                obj.awaitTask(obj.host.SetExperimentPurposeAsync(obj.expPurposeField.Value));
                obj.notifyAcquireRefresh();
                obj.refresh(false);
            catch ex
                obj.showError(ex.message, 'Data Manager');
            end
        end

        function commitSourceLabel(obj)
            try
                id = obj.currentSelection.id;
                obj.awaitTask(obj.host.SetSourceLabelAsync(id, obj.srcLabelField.Value));
                obj.notifyAcquireRefresh();
                obj.refresh(false);
            catch ex
                obj.showError(ex.message, 'Data Manager');
            end
        end

        function commitEpochGroupLabel(obj)
            try
                id = obj.currentSelection.id;
                obj.awaitTask(obj.host.SetEpochGroupLabelAsync(id, obj.grpLabelField.Value));
                obj.notifyAcquireRefresh();
                obj.refresh(false);
            catch ex
                obj.showError(ex.message, 'Data Manager');
            end
        end

        function onPropertyCellEdit(obj, ~, ~)
            % Reserved for entity property grid when host exposes descriptors.
        end

        function addSource(obj)
            try
                sp = symphonyui.ui.SymphonyDataManager.buildSearchPaths();

                % If a source is currently selected, behave like "Add Child Source"
                parentSourceId = '';
                nd = obj.getSelectedTreeNodeData();
                if ~isempty(nd) && isstruct(nd) && isfield(nd, 'kind') ...
                        && strcmp(char(string(nd.kind)), 'source')
                    parentSourceId = char(string(nd.id));
                end

                if ~isempty(parentSourceId)
                    result = symphonyui.ui.AddSourceDialog.showBlocking( ...
                        obj.fig, obj.host, sp, parentSourceId);
                else
                    result = symphonyui.ui.AddSourceDialog.showBlocking( ...
                        obj.fig, obj.host, sp);
                end

                if isempty(result)
                    return;
                end
                obj.notifyAcquireRefresh();
                obj.refresh();  % full rebuild to show new source
            catch ex
                obj.showError(ex.message, 'Data Manager Error');
            end
        end

        function beginEpochGroup(obj)
            try
                % Build search paths the same way as SymphonyApp.getSearchPaths
                sp = symphonyui.ui.SymphonyDataManager.buildSearchPaths();
                result = symphonyui.ui.BeginEpochGroupDialog.showBlocking(obj.fig, obj.host, sp);
                if isempty(result)
                    return;
                end
                obj.notifyAcquireRefresh();
                obj.refresh();  % full rebuild to show new epoch group
            catch ex
                obj.showError(ex.message, 'Data Manager Error');
            end
        end

        function endEpochGroup(obj)
            try
                obj.awaitTask(obj.host.EndEpochGroupAsync());
                % Commit everything to disk (see symphonyui.ui.FileCheckpoint);
                % SymphonyApp.getFilePersistor re-validates its wrapper.
                symphonyui.ui.FileCheckpoint.run(obj.host, 'epochGroup');
                obj.notifyAcquireRefresh();
                % Full refresh needed for endEpochGroup since the tree
                % structure changes (epoch group node state updates).
                % The incremental path only adds new nodes.
                obj.refresh();
            catch ex
                % EndEpochGroup can fail with HDF5 handle errors.
                % Log but don't block — the data is already saved.
                fprintf(2, 'WARNING: EndEpochGroup error (data is safe): %s\n', ex.message);
                obj.notifyAcquireRefresh();
            end
        end

        function notifyAcquireRefresh(obj)
            if ~isempty(obj.onAfterHostMutation)
                obj.onAfterHostMutation();
            end
        end

        function awaitTask(~, task)
            task.GetAwaiter().GetResult();
        end

        function result = awaitTaskWithResult(~, task)
            result = task.GetAwaiter().GetResult();
        end

        function showError(obj, msg, title)
            if nargin < 3
                title = 'Error';
            end
            try
                uialert(obj.parentFigure, char(msg), title);
            catch
                disp(msg);
            end
        end
    end

    methods (Static)
        function stepFlush(msg)
            % Bisection aid: with setappdata(groot, 'SymphonyDMStepFlush', true)
            % do a full drawnow after each epoch-selection step and trace it.
            try
                if isequal(getappdata(groot, 'SymphonyDMStepFlush'), true)
                    symphonyui.ui.SymphonyDataManager.trace(['flush ' msg ' ...']);
                    drawnow;
                    symphonyui.ui.SymphonyDataManager.trace(['flush ' msg ' ok']);
                end
            catch
            end
        end

        function trace(msg)
            % Diagnostic trace of the epoch preview path; enable with
            % setappdata(groot, 'SymphonyDMTrace', true).
            try
                if isequal(getappdata(groot, 'SymphonyDMTrace'), true)
                    fprintf('DM %s %s\n', datestr(now, 'HH:MM:SS.FFF'), msg);
                end
            catch
            end
        end
    end

    methods (Static, Access = private)
        function t = blockLabel(b)
            % Tree label for an epoch block: the protocol's short name plus the
            % host's time stamp, e.g. "Pulse [14:20:05]" instead of
            % "sa_labs.protocols.Pulse [14:20:05]".
            t = '';
            try
                t = char(string(b.DisplayName));
            catch
            end
            try
                shortName = symphonyui.ui.SymphonyDataManager.shortProtocolName(char(string(b.ProtocolId)));
                stamp = regexp(t, '\[.*\]$', 'match', 'once');
                if ~isempty(shortName)
                    if isempty(stamp)
                        t = shortName;
                    else
                        t = sprintf('%s %s', shortName, stamp);
                    end
                end
            catch
            end
        end

        function s = shortProtocolName(pid)
            parts = strsplit(char(pid), '.');
            s = parts{end};
        end

        function s = groupProtocolSuffix(dm, groupId)
            % "  -  Pulse, MultiPulse": the distinct protocols recorded in an
            % epoch group, in order of first appearance, so the tree shows what
            % was run without expanding the group. Empty when there are none.
            s = '';
            try
                names = {};
                n = SymphonyAppUtil.getNetCount(dm.EpochBlocks);
                for i = 1:n
                    b = SymphonyAppUtil.getNetItem(dm.EpochBlocks, i);
                    if strcmp(char(string(b.EpochGroupId)), char(string(groupId)))
                        nm = symphonyui.ui.SymphonyDataManager.shortProtocolName(char(string(b.ProtocolId)));
                        if ~isempty(nm) && ~any(strcmp(names, nm))
                            names{end + 1} = nm; %#ok<AGROW>
                        end
                    end
                end
                if ~isempty(names)
                    s = ['  -  ', strjoin(names, ', ')];
                end
            catch
            end
        end

        function paths = buildSearchPaths()
            % Build the merged search paths: defaults + Options → Search Paths.
            % Mirrors SymphonyApp.getSearchPaths().
            sp = '';
            try
                opts = symphonyui.app.Options.getDefault();
                sp = opts.searchPath;
                if isa(sp, 'function_handle'), sp = sp(); end
                sp = char(sp);
            catch
            end
            appDir = symphonyui.ui.symphonyAppRoot();
            defaultPaths = { ...
                fullfile(appDir, 'code', 'src', 'resources', 'examples') };
            if isempty(sp)
                paths = defaultPaths;
            else
                paths = [defaultPaths, strsplit(sp, ';')];
            end
        end
    end
end
