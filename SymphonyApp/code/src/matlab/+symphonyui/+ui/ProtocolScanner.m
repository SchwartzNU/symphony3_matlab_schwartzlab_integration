classdef ProtocolScanner
    %PROTOCOLSCANNER  Discovers subclasses on the MATLAB path by scanning +package dirs.
    %   Uses meta.class reflection to find concrete (non-abstract) subclasses of a
    %   given superclass within configured search paths.  Replaces the old
    %   ClassRepository-based discovery for the UIFigure migration.
    %
    %   Usage:
    %       protocols = symphonyui.ui.ProtocolScanner.discover(searchPaths);
    %       rigs      = symphonyui.ui.ProtocolScanner.discoverRigs(searchPaths);
    %       items     = symphonyui.ui.ProtocolScanner.discoverSubclasses(searchPaths, superclassName);
    %
    %   Each element of the returned struct array has fields:
    %       id          - Full class name (e.g. 'io.protocols.Pulse')
    %       displayName - Short class name (e.g. 'Pulse')

    methods (Static)

        function results = discoverSubclasses(searchPaths, superclassName)
            %DISCOVERSUBCLASSES  Scan directories for subclasses of a given superclass.
            %   searchPaths:    semicolon-delimited string or cell array of dirs.
            %   superclassName: fully-qualified class name (e.g. 'symphonyui.core.Protocol').

            if nargin < 1 || isempty(searchPaths)
                results = struct('id', {}, 'displayName', {});
                return;
            end
            if ischar(searchPaths) || isstring(searchPaths)
                searchPaths = strsplit(char(searchPaths), ';');
            end

            % Ensure search-path directories are on the MATLAB path so that
            % meta.class.fromName can resolve the classes inside +package dirs.
            % Use '-end' so user search paths don't shadow the SymphonyApp's
            % own examples (which addAppPaths places at the top with '-begin').
            for i = 1:numel(searchPaths)
                d = strtrim(searchPaths{i});
                if ~isempty(d) && isfolder(d)
                    pathDirs = strsplit(path, pathsep);
                    if ~any(strcmp(d, pathDirs))
                        addpath(d, '-end');
                    end
                end
            end

            classNames = {};
            for i = 1:numel(searchPaths)
                d = strtrim(searchPaths{i});
                if ~isempty(d) && isfolder(d)
                    classNames = [classNames, ...
                        symphonyui.ui.ProtocolScanner.scanDirectory(d, '', superclassName)]; %#ok<AGROW>
                end
            end

            % De-duplicate and sort
            classNames = unique(classNames);
            classNames = sort(classNames);

            if ~isempty(classNames)
                fprintf('ProtocolScanner: found %d classes for %s: %s\n', ...
                    numel(classNames), superclassName, strjoin(classNames, ', '));
            end

            % Build output struct array
            results = struct('id', {}, 'displayName', {});
            for i = 1:numel(classNames)
                cn = classNames{i};
                parts = strsplit(cn, '.');
                results(end + 1).id = cn; %#ok<AGROW>
                results(end).displayName = parts{end};
            end
        end

        function protocols = discover(searchPaths)
            %DISCOVER  Scan directories for Protocol subclasses.
            protocols = symphonyui.ui.ProtocolScanner.discoverSubclasses( ...
                searchPaths, 'symphonyui.core.Protocol');
        end

        function rigs = discoverRigs(searchPaths)
            %DISCOVERRIGS  Scan directories for RigDescription subclasses.
            rigs = symphonyui.ui.ProtocolScanner.discoverSubclasses( ...
                searchPaths, 'symphonyui.core.descriptions.RigDescription');
        end

        function groups = discoverEpochGroups(searchPaths)
            %DISCOVEREPOCHGROUPS  Scan directories for EpochGroupDescription subclasses.
            groups = symphonyui.ui.ProtocolScanner.discoverSubclasses( ...
                searchPaths, 'symphonyui.core.persistent.descriptions.EpochGroupDescription');
        end

        function sources = discoverSources(searchPaths)
            %DISCOVERSOURCES  Scan directories for SourceDescription subclasses.
            sources = symphonyui.ui.ProtocolScanner.discoverSubclasses( ...
                searchPaths, 'symphonyui.core.persistent.descriptions.SourceDescription');
        end

        function modules = discoverModules(searchPaths)
            %DISCOVERMODULES  Scan directories for Module subclasses.
            modules = symphonyui.ui.ProtocolScanner.discoverSubclasses( ...
                searchPaths, 'symphonyui.ui.Module');
        end

        function experiments = discoverExperiments(searchPaths)
            %DISCOVEREXPERIMENTS  Scan directories for ExperimentDescription subclasses.
            experiments = symphonyui.ui.ProtocolScanner.discoverSubclasses( ...
                searchPaths, 'symphonyui.core.persistent.descriptions.ExperimentDescription');
        end

        function props = getProtocolProperties(protocolObj)
            %GETPROTOCOLPROPERTIES  Extract editable property info from a protocol instance.
            %   Returns a struct array with fields: name, displayName, value, primitiveType,
            %   isReadOnly, isHidden, description, domain.
            %
            %   domain is a cell array of allowed string values (for dropdown rendering)
            %   when a companion <propName>Type property exists holding a
            %   symphonyui.core.PropertyType with a non-empty domain.

            mc = metaclass(protocolObj);
            props = struct('name', {}, 'displayName', {}, 'value', {}, ...
                'primitiveType', {}, 'isReadOnly', {}, 'isHidden', {}, ...
                'description', {}, 'domain', {});

            for i = 1:numel(mc.PropertyList)
                mp = mc.PropertyList(i);

                % Skip non-public, abstract, or inherited-from-handle properties
                if ~strcmp(mp.GetAccess, 'public')
                    continue;
                end
                if mp.Abstract
                    continue;
                end
                % Skip properties defined by handle, matlab.mixin.*, etc.
                defClass = mp.DefiningClass.Name;
                if startsWith(defClass, 'matlab.') || strcmp(defClass, 'handle')
                    continue;
                end

                isHidden = mp.Hidden;
                isReadOnly = mp.Constant || ~strcmp(mp.SetAccess, 'public') ...
                    || (mp.Dependent && isempty(mp.SetMethod));

                % Get current value (may fail for dependent props without get)
                try
                    val = protocolObj.(mp.Name);
                catch
                    val = [];
                end

                % Infer primitive type from value
                primType = symphonyui.ui.ProtocolScanner.inferType(val);

                % Build display name from property name (camelCase → spaced)
                dispName = symphonyui.ui.ProtocolScanner.humanize(mp.Name);

                % Extract description from property comment if available
                desc = '';
                if ~isempty(mp.Description)
                    desc = mp.Description;
                end

                % Check for a companion <name>Type property holding a
                % PropertyType with an enumerated domain (e.g. ledType).
                domain = {};
                typePropName = [mp.Name 'Type'];
                try
                    typeObj = protocolObj.(typePropName);
                    if isa(typeObj, 'symphonyui.core.PropertyType') ...
                            && iscell(typeObj.domain) && ~isempty(typeObj.domain)
                        domain = typeObj.domain;
                    end
                catch
                    % No companion type property — that's fine
                end

                props(end + 1).name = mp.Name; %#ok<AGROW>
                props(end).displayName = dispName;
                props(end).value = val;
                props(end).primitiveType = primType;
                props(end).isReadOnly = isReadOnly;
                props(end).isHidden = isHidden;
                props(end).description = desc;
                props(end).domain = domain;
            end
        end

    end

    methods (Static)

        function tf = isSubclassOf(mc, superclassName)
            %ISSUBCLASSOF  Check if a metaclass is a subclass of the given name.
            tf = false;
            for i = 1:numel(mc.SuperclassList)
                if strcmp(mc.SuperclassList(i).Name, superclassName)
                    tf = true;
                    return;
                end
                if symphonyui.ui.ProtocolScanner.isSubclassOf(mc.SuperclassList(i), superclassName)
                    tf = true;
                    return;
                end
            end
        end

    end

    methods (Static, Access = private)

        function classNames = scanDirectory(dirPath, packagePrefix, superclassName)
            %SCANDIRECTORY  Recursively scan a directory for subclasses.
            classNames = {};
            listing = dir(dirPath);
            for i = 1:numel(listing)
                entry = listing(i);
                if strcmp(entry.name, '.') || strcmp(entry.name, '..')
                    continue;
                end
                [~, name, ext] = fileparts(entry.name);

                if entry.isdir && ~isempty(name) && name(1) == '+'
                    % Package directory — recurse
                    subPackage = name(2:end);  % strip leading +
                    if isempty(packagePrefix)
                        newPrefix = subPackage;
                    else
                        newPrefix = [packagePrefix '.' subPackage];
                    end
                    classNames = [classNames, ...
                        symphonyui.ui.ProtocolScanner.scanDirectory( ...
                            fullfile(dirPath, entry.name), newPrefix, superclassName)]; %#ok<AGROW>

                elseif strcmpi(ext, '.m') && ~isempty(packagePrefix)
                    % .m file inside a package — check if it's a subclass
                    className = [packagePrefix '.' name];
                    try
                        mc = meta.class.fromName(className);
                        if isempty(mc)
                            % meta.class.fromName returned empty
                        elseif mc.Abstract
                            % Skip abstract classes
                        else
                            if symphonyui.ui.ProtocolScanner.isSubclassOf(mc, superclassName)
                                classNames{end + 1} = className; %#ok<AGROW>
                            end
                        end
                    catch scanEx
                        fprintf(2, 'ProtocolScanner: skipping "%s": %s\n', className, scanEx.message);
                    end
                end
            end
        end

        function t = inferType(val)
            %INFERTYPE  Infer a primitive type string from a MATLAB value.
            if islogical(val)
                t = 'logical';
            elseif isa(val, 'double')
                t = 'double';
            elseif isa(val, 'single')
                t = 'single';
            elseif isinteger(val)
                t = class(val);  % int8, uint16, int32, etc.
            elseif ischar(val) || isstring(val)
                t = 'char';
            else
                t = 'char';  % fallback: display as string
            end
        end

        function d = humanize(name)
            %HUMANIZE  Convert camelCase property name to display name.
            %   'sampleRate' -> 'Sample Rate', 'numEpochs' -> 'Num Epochs'
            d = regexprep(name, '([a-z])([A-Z])', '$1 $2');
            d = regexprep(d, '([A-Z]+)([A-Z][a-z])', '$1 $2');
            if ~isempty(d)
                d(1) = upper(d(1));
            end
        end

    end
end
