classdef AddSourceDialog < handle
    %ADDSOURCEDIALOG  Document → Add Source (uifigure modal dialog).
    %   Collects source type, parent source, and label, then adds the source
    %   via the C# AcquisitionHost.  Source types are discovered from the
    %   search paths (+sources packages).  The parent dropdown is filtered
    %   based on the selected type's allowable parent types.

    properties (Access = private)
        fig matlab.ui.Figure
        parentFigure
        host  % IAcquisitionHost (.NET)
        result  % true if source added, [] if cancelled

        descDropdown matlab.ui.control.DropDown
        parentDropdown matlab.ui.control.DropDown
        labelField matlab.ui.control.EditField
        addButton matlab.ui.control.Button
        cancelButton matlab.ui.control.Button

        % Discovered source type metadata
        sourceTypes     % struct array: id, displayName
        sourceInstances % cell array of instantiated SourceDescription objects

        % Existing sources from the data file
        existingSources % struct array: id, label, parentSourceId, className

        % When adding a child source, restrict to types whose parent matches
        % this specific source class name.
        restrictToParentClassName char = ''
    end

    methods (Static)
        function result = showBlocking(parentFigure, host, searchPaths, preselectedParentId)
            %SHOWBLOCKING  Open modal Add Source dialog and block until done.
            %   preselectedParentId (optional): if provided, pre-selects this
            %   source as the parent in the Parent dropdown.
            if nargin < 3
                searchPaths = {};
            end
            if nargin < 4
                preselectedParentId = '';
            end
            dlg = symphonyui.ui.AddSourceDialog(parentFigure, host, searchPaths, preselectedParentId);
            dlg.fig.Visible = 'on';
            uiwait(dlg.fig);
            result = dlg.result;
        end
    end

    methods (Access = private)
        function obj = AddSourceDialog(parentFigure, host, searchPaths, preselectedParentId)
            if nargin < 4
                preselectedParentId = '';
            end
            obj.parentFigure = parentFigure;
            obj.host = host;
            obj.result = [];
            obj.sourceTypes = struct('id', {}, 'displayName', {});
            obj.sourceInstances = {};
            obj.existingSources = struct('id', {}, 'label', {}, 'parentSourceId', {}, 'className', {});

            obj.discoverSourceTypes(searchPaths);
            obj.loadExistingSources();

            % When a parent is pre-selected (Add Child Source), find its
            % class name so we can restrict the description dropdown to
            % only valid child types.
            if ~isempty(preselectedParentId)
                for si = 1:numel(obj.existingSources)
                    if strcmp(obj.existingSources(si).id, preselectedParentId)
                        obj.restrictToParentClassName = obj.existingSources(si).className;
                        break;
                    end
                end
            end

            obj.buildUi();
            obj.populateDescriptions();
            obj.onDescriptionChanged();  % set initial parent list & label

            % Pre-select the parent source if provided
            if ~isempty(preselectedParentId)
                try
                    ids = obj.parentDropdown.ItemsData;
                    if iscell(ids) && any(strcmp(ids, preselectedParentId))
                        obj.parentDropdown.Value = preselectedParentId;
                    end
                catch
                end
            end
        end

        function discoverSourceTypes(obj, searchPaths)
            obj.sourceTypes = symphonyui.ui.ProtocolScanner.discoverSources(searchPaths);
            % Pre-instantiate each source type to read allowableParentTypes
            % and property descriptors. If construction fails (e.g. missing
            % calibration resources), build a stub with inferred parent types
            % and inherited property descriptors from the abstract base class.
            obj.sourceInstances = cell(1, numel(obj.sourceTypes));
            for i = 1:numel(obj.sourceTypes)
                try
                    ctor = str2func(obj.sourceTypes(i).id);
                    obj.sourceInstances{i} = ctor();
                catch
                    % Construction failed — build a stub with inferred
                    % allowable parent types and base-class properties.
                    obj.sourceInstances{i} = obj.buildStubSourceDescription(obj.sourceTypes(i).id);
                end
            end
        end

        function stub = buildStubSourceDescription(obj, className)
            %BUILDSTUBSOURCEDESCRIPTION  Create a minimal SourceDescription
            %   stub from metaclass reflection when the real constructor fails.
            %   Infers allowable parent types from the superclass chain and
            %   inherits property descriptors from the nearest constructable
            %   ancestor class (e.g. Subject defines id, sex, etc.).
            stub = [];
            try
                mc = meta.class.fromName(className);
                if isempty(mc), return; end

                isSubj = symphonyui.ui.ProtocolScanner.isSubclassOf(mc, 'symphonyui.core.persistent.descriptions.SourceDescription');
                if ~isSubj, return; end

                % Create a bare SourceDescription and set label
                stub = symphonyui.core.persistent.descriptions.SourceDescription();
                parts = strsplit(className, '.');
                stub.label = appbox.humanize(parts{end});

                pkgParts = parts(1:end-1);
                pkgPrefix = strjoin(pkgParts, '.');

                % Walk up the superclass chain: try to construct each
                % ancestor to get its property descriptors. The first
                % non-abstract ancestor that succeeds gives us the inherited
                % properties (Subject adds id/sex/etc., Preparation adds
                % time/region/etc.).
                ancestors = {};
                symphonyui.ui.AddSourceDialog.collectAncestors(mc, ancestors);
                currentMc = mc;
                while ~isempty(currentMc.SuperclassList)
                    for ai = 1:numel(currentMc.SuperclassList)
                        anc = currentMc.SuperclassList(ai);
                        if symphonyui.ui.ProtocolScanner.isSubclassOf(anc, 'symphonyui.core.persistent.descriptions.SourceDescription') ...
                                || strcmp(anc.Name, 'symphonyui.core.persistent.descriptions.SourceDescription')
                            if ~anc.Abstract
                                % Try to construct this ancestor
                                try
                                    ancCtor = str2func(anc.Name);
                                    ancInst = ancCtor();
                                    % Copy its property descriptors
                                    descs = ancInst.getPropertyDescriptors();
                                    for di = 1:numel(descs)
                                        stub.addProperty(descs(di).name, descs(di).value, ...
                                            'type', descs(di).type, ...
                                            'displayName', descs(di).displayName, ...
                                            'description', descs(di).description, ...
                                            'isReadOnly', descs(di).isReadOnly, ...
                                            'isHidden', descs(di).isHidden);
                                    end
                                catch
                                end
                            end
                            currentMc = anc;
                            break;
                        end
                    end
                    % Safety: stop if we've reached the base class
                    if strcmp(currentMc.Name, 'symphonyui.core.persistent.descriptions.SourceDescription')
                        break;
                    end
                end

                % Determine allowable parent type from the superclass role
                roleSet = false;
                for s = 1:numel(mc.SuperclassList)
                    scName = mc.SuperclassList(s).Name;
                    if endsWith(scName, '.Subject') || endsWith(scName, 'SourceDescription')
                        stub.addAllowableParentType([]);
                        roleSet = true;
                        break;
                    end
                    if endsWith(scName, '.Preparation')
                        siblingSubjects = obj.findSiblingByRole(pkgPrefix, 'Subject');
                        if isempty(siblingSubjects)
                            stub.addAllowableParentType([]);
                        else
                            for si = 1:numel(siblingSubjects)
                                stub.addAllowableParentType(siblingSubjects{si});
                            end
                        end
                        roleSet = true;
                        break;
                    end
                    if endsWith(scName, '.Cell')
                        siblingPreps = obj.findSiblingByRole(pkgPrefix, 'Preparation');
                        if isempty(siblingPreps)
                            stub.addAllowableParentType([]);
                        else
                            for si = 1:numel(siblingPreps)
                                stub.addAllowableParentType(siblingPreps{si});
                            end
                        end
                        roleSet = true;
                        break;
                    end
                end
                if ~roleSet
                    stub.addAllowableParentType([]);
                end
            catch
                stub = [];
            end
        end

        function matches = findSiblingByRole(obj, pkgPrefix, roleName)
            %FINDSIBLINGBYROLE  Find source types in the same or parent package
            %   whose class name ends with the given role (e.g. 'Subject').
            matches = {};
            for i = 1:numel(obj.sourceTypes)
                sid = obj.sourceTypes(i).id;
                parts = strsplit(sid, '.');
                if strcmp(parts{end}, roleName) || endsWith(sid, ['.' roleName])
                    % Check if it's in the same package tree
                    if startsWith(sid, pkgPrefix) || startsWith(pkgPrefix, strjoin(parts(1:end-1), '.'))
                        matches{end+1} = sid; %#ok<AGROW>
                    end
                end
            end
        end

        function loadExistingSources(obj)
            try
                dm = obj.host.GetDataManagerStateAsync().GetAwaiter().GetResult();
                sources = dm.Sources;
                n = SymphonyAppUtil.getNetCount(sources);
                for i = 1:n
                    s = SymphonyAppUtil.getNetItem(sources, i);
                    obj.existingSources(i).id = char(s.Id);
                    lbl = char(s.Label);
                    if isempty(lbl)
                        lbl = sprintf('Source %d', i);
                    end
                    obj.existingSources(i).label = lbl;
                    pid = s.ParentSourceId;
                    if isempty(pid)
                        obj.existingSources(i).parentSourceId = '';
                    else
                        obj.existingSources(i).parentSourceId = char(pid);
                    end
                    obj.existingSources(i).className = '';
                end

                % Read description type from each source's HDF5 resources.
                % Entity.newEntity() stores it as a resource named 'descriptionType'.
                try
                    cper = obj.host.GetPersistor();
                    if ~isempty(cper)
                        allSrcList = symphonyui.ui.AddSourceDialog.collectAllSources(cper.Experiment);
                        for si = 1:numel(allSrcList)
                            csrc = allSrcList{si};
                            srcId = strrep(char(csrc.UUID.ToString()), '-', '');
                            try
                                factory = symphonyui.core.persistent.EntityFactory();
                                pSrc = symphonyui.core.persistent.Source(csrc, factory);
                                cn = pSrc.getDescriptionType();
                                if ~isempty(cn)
                                    for k = 1:numel(obj.existingSources)
                                        if strcmp(obj.existingSources(k).id, srcId)
                                            obj.existingSources(k).className = cn;
                                            break;
                                        end
                                    end
                                end
                            catch
                            end
                        end
                    end
                catch
                end
            catch
            end
        end

        function buildUi(obj)
            w = 400;
            h = 190;
            pos = obj.centerOnParent(w, h);

            obj.fig = uifigure( ...
                'Name', 'Add Source', ...
                'Position', pos, ...
                'WindowStyle', 'modal', ...
                'Color', [0.94 0.94 0.94], ...
                'Resize', 'off', ...
                'CloseRequestFcn', @(~,~)obj.onCancel(), ...
                'KeyPressFcn', @(~,e)obj.onKeyPress(e), ...
                'WindowKeyPressFcn', @(~,e)obj.onKeyPress(e));

            main = uigridlayout(obj.fig, [4 2]);
            main.RowHeight = {28, 28, 28, 40};
            main.ColumnWidth = {90, '1x'};
            main.Padding = [12 12 12 12];
            main.RowSpacing = 8;
            main.ColumnSpacing = 8;

            % Row 1: Source type (Description)
            lbl1 = uilabel(main, 'Text', 'Description:', 'HorizontalAlignment', 'right');
            lbl1.Layout.Row = 1; lbl1.Layout.Column = 1;
            obj.descDropdown = uidropdown(main, ...
                'Items', {'(loading...)'}, ...
                'ValueChangedFcn', @(~,~)obj.onDescriptionChanged());
            obj.descDropdown.Layout.Row = 1; obj.descDropdown.Layout.Column = 2;

            % Row 2: Parent source
            lbl2 = uilabel(main, 'Text', 'Parent:', 'HorizontalAlignment', 'right');
            lbl2.Layout.Row = 2; lbl2.Layout.Column = 1;
            obj.parentDropdown = uidropdown(main, 'Items', {'(None)'}, 'ItemsData', {''});
            obj.parentDropdown.Layout.Row = 2; obj.parentDropdown.Layout.Column = 2;

            % Row 3: Label
            lbl3 = uilabel(main, 'Text', 'Label:', 'HorizontalAlignment', 'right');
            lbl3.Layout.Row = 3; lbl3.Layout.Column = 1;
            obj.labelField = uieditfield(main, 'text', 'Value', 'Source', ...
                'ValueChangedFcn', @(~,~)obj.onAdd());
            obj.labelField.Layout.Row = 3; obj.labelField.Layout.Column = 2;

            % Row 4: Buttons
            btnGrid = uigridlayout(main, [1 3]);
            btnGrid.Layout.Row = 4;
            btnGrid.Layout.Column = [1 2];
            btnGrid.ColumnWidth = {'1x', 80, 80};
            btnGrid.Padding = [0 0 0 0];

            uilabel(btnGrid, 'Text', '');  % spacer
            obj.addButton = uibutton(btnGrid, 'Text', 'Add', ...
                'ButtonPushedFcn', @(~,~)obj.onAdd());
            obj.cancelButton = uibutton(btnGrid, 'Text', 'Cancel', ...
                'ButtonPushedFcn', @(~,~)obj.onCancel());

            symphonyui.ui.DialogUtil.setKeyPressFcnRecursive(obj.fig, @(~,e)obj.onKeyPress(e));
        end

        function populateDescriptions(obj)
            % Filter source types to only show those appropriate for the
            % current hierarchy level:
            % - If no sources exist → show only types with allowableParent = []
            % - Otherwise → show types whose allowable parent matches an existing source
            if isempty(obj.sourceTypes)
                obj.descDropdown.Items = {'(no source types available)'};
                obj.descDropdown.ItemsData = {''};
                obj.addButton.Enable = 'off';
                return;
            end

            % Collect class names of existing sources (stored as properties)
            existingClassNames = {};
            for i = 1:numel(obj.existingSources)
                cn = obj.existingSources(i).className;
                if ~isempty(cn)
                    existingClassNames{end+1} = cn; %#ok<AGROW>
                end
            end

            names = {};
            ids = {};
            for i = 1:numel(obj.sourceTypes)
                inst = obj.sourceInstances{i};
                if isempty(inst)
                    continue;
                end
                allowable = inst.getAllowableParentTypes();

                % Check if this source type can be added given the current
                % hierarchy state.
                canAdd = false;

                % When adding a child source, ONLY show types whose
                % allowable parent matches the specific parent class.
                if ~isempty(obj.restrictToParentClassName)
                    parentCn = obj.restrictToParentClassName;
                    for j = 1:numel(allowable)
                        if isempty(allowable{j})
                            continue;  % skip top-level — we need a specific parent match
                        end
                        % Exact match
                        if strcmp(allowable{j}, parentCn)
                            canAdd = true;
                            break;
                        end
                        % Subclass check
                        try
                            mc = meta.class.fromName(parentCn);
                            if ~isempty(mc) && symphonyui.ui.ProtocolScanner.isSubclassOf(mc, allowable{j})
                                canAdd = true;
                                break;
                            end
                        catch
                        end
                        % Role-based check within same namespace
                        try
                            allowParts = strsplit(allowable{j}, '.');
                            allowRole = allowParts{end};
                            candidateParts = strsplit(obj.sourceTypes(i).id, '.');
                            candidateNs = strjoin(candidateParts(1:end-1), '.');
                            cnParts = strsplit(parentCn, '.');
                            existingNs = strjoin(cnParts(1:end-1), '.');
                            nsMatch = startsWith(candidateNs, existingNs) || ...
                                      startsWith(existingNs, candidateNs);
                            if nsMatch
                                mc = meta.class.fromName(parentCn);
                                if ~isempty(mc) && symphonyui.ui.AddSourceDialog.classExtendsRole(mc, allowRole)
                                    canAdd = true;
                                    break;
                                end
                            end
                        catch
                        end
                    end
                elseif isempty(obj.existingSources)
                    % No sources yet — only allow top-level (parent = [])
                    for j = 1:numel(allowable)
                        if isempty(allowable{j})
                            canAdd = true;
                            break;
                        end
                    end
                else
                    % Sources exist — check if any existing source matches
                    % an allowable parent type.
                    for j = 1:numel(allowable)
                        if isempty(allowable{j})
                            canAdd = true;  % top-level always allowed
                            break;
                        end
                        % Check if any existing source is an instance of
                        % (or subclass of) the allowable parent type
                        for k = 1:numel(obj.existingSources)
                            cn = obj.existingSources(k).className;
                            if ~isempty(cn)
                                % Exact match
                                if strcmp(cn, allowable{j})
                                    canAdd = true;
                                    break;
                                end
                                % Subclass check
                                try
                                    mc = meta.class.fromName(cn);
                                    if ~isempty(mc) && symphonyui.ui.ProtocolScanner.isSubclassOf(mc, allowable{j})
                                        canAdd = true;
                                        break;
                                    end
                                catch
                                end
                                % Fallback: check if the existing source's
                                % class hierarchy shares the same abstract
                                % base role as the allowable parent type,
                                % BUT only within the same namespace.
                                try
                                    allowParts = strsplit(allowable{j}, '.');
                                    allowRole = allowParts{end};  % e.g. 'Subject', 'Preparation'
                                    % Get the candidate source type's namespace
                                    candidateParts = strsplit(obj.sourceTypes(i).id, '.');
                                    candidateNs = strjoin(candidateParts(1:end-1), '.');
                                    % Get the existing source's namespace
                                    cnParts = strsplit(cn, '.');
                                    existingNs = strjoin(cnParts(1:end-1), '.');
                                    % Only allow cross-namespace role matching if
                                    % the source namespaces share a common root
                                    % (e.g. both under io.sources.animal)
                                    nsMatch = startsWith(candidateNs, existingNs) || ...
                                              startsWith(existingNs, candidateNs);
                                    if nsMatch
                                        mc = meta.class.fromName(cn);
                                        if ~isempty(mc)
                                            if symphonyui.ui.AddSourceDialog.classExtendsRole(mc, allowRole)
                                                canAdd = true;
                                                break;
                                            end
                                        end
                                    end
                                catch
                                end
                            end
                        end
                        if canAdd, break; end
                    end
                end

                if canAdd
                    % Show display name with namespace
                    fullId = obj.sourceTypes(i).id;
                    dispName = obj.sourceTypes(i).displayName;
                    names{end+1} = sprintf('%s (%s)', dispName, fullId); %#ok<AGROW>
                    ids{end+1} = fullId; %#ok<AGROW>
                end
            end

            if isempty(names)
                obj.descDropdown.Items = {'(no applicable source types)'};
                obj.descDropdown.ItemsData = {''};
                obj.addButton.Enable = 'off';
            else
                obj.descDropdown.Items = names;
                obj.descDropdown.ItemsData = ids;
            end
        end

        function onDescriptionChanged(obj)
            % When the source type changes, update the parent dropdown
            % to only show sources whose type is in the allowable parent types,
            % and update the label field.
            selectedId = obj.descDropdown.Value;
            if isempty(selectedId) || isempty(char(selectedId))
                return;
            end

            % Find the selected source instance
            idx = find(strcmp({obj.sourceTypes.id}, selectedId), 1);
            if isempty(idx) || isempty(obj.sourceInstances{idx})
                return;
            end

            desc = obj.sourceInstances{idx};

            % Update label from source type display name
            obj.labelField.Value = desc.label;

            % Get allowable parent types
            allowable = desc.getAllowableParentTypes();

            % Check if top-level is allowed (empty entry in allowable types)
            allowTopLevel = false;
            parentClassNames = {};
            for i = 1:numel(allowable)
                if isempty(allowable{i})
                    allowTopLevel = true;
                else
                    parentClassNames{end+1} = allowable{i}; %#ok<AGROW>
                end
            end

            % Build filtered parent list from existing sources
            labels = {};
            ids = {};
            if allowTopLevel
                labels{end+1} = '(None)';
                ids{end+1} = '';
            end

            for i = 1:numel(obj.existingSources)
                if isempty(parentClassNames)
                    % No specific parent type required (and allowTopLevel
                    % is true), so don't add existing sources as parents
                    continue;
                end
                % Check if this existing source's label matches any of the
                % allowable parent type display names. Since we don't track
                % the class name of existing sources from the HDF file, we
                % allow any existing source as a potential parent when
                % specific parent types are required.
                labels{end+1} = obj.existingSources(i).label; %#ok<AGROW>
                ids{end+1} = obj.existingSources(i).id; %#ok<AGROW>
            end

            if isempty(labels)
                labels = {'(None)'};
                ids = {''};
            end

            obj.parentDropdown.Items = labels;
            obj.parentDropdown.ItemsData = ids;

            % Default to the deepest (leaf) source if one is available
            if numel(ids) > 1
                % Pick the last entry which is typically the deepest
                leafIdx = numel(ids);
                for i = 2:numel(ids)  % skip (None)
                    isParent = false;
                    for j = 2:numel(ids)
                        if strcmp(ids{i}, obj.getParentIdForSource(ids{j}))
                            isParent = true;
                            break;
                        end
                    end
                    if ~isParent
                        leafIdx = i;
                    end
                end
                obj.parentDropdown.Value = ids{leafIdx};
            end
        end

        function pid = getParentIdForSource(obj, sourceId)
            pid = '';
            for i = 1:numel(obj.existingSources)
                if strcmp(obj.existingSources(i).id, sourceId)
                    pid = obj.existingSources(i).parentSourceId;
                    return;
                end
            end
        end

        function onAdd(obj)
            label = strtrim(obj.labelField.Value);
            if isempty(label)
                uialert(obj.fig, 'Please enter a source label.', 'Add Source');
                return;
            end
            parentId = obj.parentDropdown.Value;
            if isempty(parentId)
                parentId = '';
            end

            % Get the selected source description and instance
            selectedDescId = obj.descDropdown.Value;
            descIdx = find(strcmp({obj.sourceTypes.id}, selectedDescId), 1);
            descInstance = [];
            if ~isempty(descIdx) && ~isempty(obj.sourceInstances{descIdx})
                descInstance = obj.sourceInstances{descIdx};
            end

            try
                % Step 1: Create the source via the C# host so the Data
                % Manager tree stays in sync.
                if isempty(char(parentId))
                    obj.host.AddSourceAsync(label).GetAwaiter().GetResult();
                else
                    obj.host.AddSourceAsync(label, parentId).GetAwaiter().GetResult();
                end

                % Step 2: Write description properties and resources to
                % the HDF5 source via the persistor.
                if ~isempty(descInstance)
                    try
                        cper = obj.host.GetPersistor();
                        if ~isempty(cper)
                            % Find the source we just created (last in list)
                            lastSrc = symphonyui.ui.AddSourceDialog.findLastSource(cper.Experiment);
                            if ~isempty(lastSrc)
                                factory = symphonyui.core.persistent.EntityFactory();
                                symphonyui.core.persistent.Source.newSource( ...
                                    lastSrc, factory, descInstance);
                            else
                                fprintf(2, 'onAdd: could not find newly created source in persistor\n');
                            end
                        end
                    catch ex2
                        fprintf(2, 'onAdd: failed to write description properties: %s\n', ex2.message);
                    end
                end

                obj.result = struct('success', true, 'sourceDescriptionId', char(selectedDescId));
                obj.closeDialog();
            catch ex
                fprintf(2, '\n=== Add Source Error ===\n%s\n', getReport(ex, 'extended'));
                uialert(obj.fig, ex.message, 'Add Source Error');
            end
        end

        function onCancel(obj)
            obj.result = [];
            obj.closeDialog();
        end

        function onKeyPress(obj, event)
            switch event.Key
                case 'return'
                    obj.onAdd();
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

    methods (Static)
        function allSrcs = collectAllSources(experimentOrSource)
            %COLLECTALLSOURCES  Recursively collect all IPersistentSource objects.
            %   Uses SourcesList() (returns concrete List<T>) instead of Sources
            %   (returns LINQ IEnumerable<T> that MATLAB cannot enumerate).
            allSrcs = {};
            try
                srcList = experimentOrSource.SourcesList();
                n = srcList.Count;
                for i = 1:n
                    src = srcList.Item(i - 1);
                    allSrcs{end+1} = src; %#ok<AGROW>
                    childSrcs = symphonyui.ui.AddSourceDialog.collectAllSources(src);
                    allSrcs = [allSrcs, childSrcs]; %#ok<AGROW>
                end
            catch ex
                fprintf(2, 'collectAllSources error: %s\n', ex.message);
            end
        end

        function tf = classExtendsRole(mc, roleName)
            %CLASSEXTENDSROLE  Check if a metaclass or any of its ancestors
            %   has a short name matching roleName (e.g. 'Subject', 'Preparation').
            %   This enables cross-package matching: io.sources.animal.Animal
            %   extends io.sources.Subject, which matches role 'Subject'.
            tf = false;
            parts = strsplit(mc.Name, '.');
            if strcmp(parts{end}, roleName)
                tf = true;
                return;
            end
            for i = 1:numel(mc.SuperclassList)
                if symphonyui.ui.AddSourceDialog.classExtendsRole(mc.SuperclassList(i), roleName)
                    tf = true;
                    return;
                end
            end
        end

        function lastSrc = findLastSource(experimentOrSource)
            %FINDLASTSOURCE  Find the most recently added source by walking
            %   the source tree recursively (last in traversal order).
            lastSrc = [];
            try
                srcList = experimentOrSource.SourcesList();
                n = srcList.Count;
                for i = 1:n
                    lastSrc = srcList.Item(i - 1);
                    childLast = symphonyui.ui.AddSourceDialog.findLastSource(lastSrc);
                    if ~isempty(childLast)
                        lastSrc = childLast;
                    end
                end
            catch ex
                fprintf(2, 'findLastSource error: %s\n', ex.message);
            end
        end
    end
end
