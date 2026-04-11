function fixH5ForSymphony2(h5path, varargin)
%FIXH5FORSYMPHONY2  Patch Symphony 3 HDF5 files for Symphony 2 compatibility.
%
%   fixH5ForSymphony2(FILE) patches the given .h5 file in-place so that
%   Symphony 2 can open it without "Struct contents reference from a
%   non-struct array object" errors.
%
%   fixH5ForSymphony2(FILE, 'DryRun', true) scans the file and reports
%   what would be fixed without modifying anything.
%
%   The problem: Symphony 3 saves PropertyDescriptor.type as [] when no
%   explicit type constraint is set. Symphony 2's loadobj passes [] to
%   set.type, which calls [].primitiveType and crashes.
%
%   The fix: Re-serialize all propertyDescriptors resources, replacing
%   type=[] with a valid struct inferred from each property's value.
%
%   Usage:
%     symphonyui.ui.fixH5ForSymphony2('C:\data\2026-04-05.h5')
%     symphonyui.ui.fixH5ForSymphony2('C:\data\2026-04-05.h5', 'DryRun', true)
%
%   To fix all .h5 files in a directory:
%     files = dir('C:\data\*.h5');
%     for i = 1:numel(files)
%         symphonyui.ui.fixH5ForSymphony2(fullfile(files(i).folder, files(i).name));
%     end

    p = inputParser();
    p.addRequired('h5path', @ischar);
    p.addParameter('DryRun', false, @islogical);
    p.parse(h5path, varargin{:});
    dryRun = p.Results.DryRun;

    if ~exist(h5path, 'file')
        error('File not found: %s', h5path);
    end

    fprintf('\n=== fixH5ForSymphony2 ===\n');
    fprintf('File: %s\n', h5path);
    if dryRun
        fprintf('Mode: DRY RUN (no changes will be made)\n');
    else
        fprintf('Mode: PATCHING\n');
    end
    fprintf('\n');

    % Create backup before modifying
    if ~dryRun
        backupPath = [h5path '.bak'];
        if ~exist(backupPath, 'file')
            fprintf('Creating backup: %s\n', backupPath);
            copyfile(h5path, backupPath);
        else
            fprintf('Backup already exists: %s\n', backupPath);
        end
    end

    % Open file and scan for resource groups
    info = h5info(h5path);
    nFixed = 0;
    nScanned = 0;
    nSkipped = 0;

    % Recursively find all 'resources' groups
    resourcePaths = {};
    findResourceGroups(info, '', resourcePaths);

    function findResourceGroups(groupInfo, currentPath, ~)
        if isfield(groupInfo, 'Groups') && ~isempty(groupInfo.Groups)
            for gi = 1:numel(groupInfo.Groups)
                g = groupInfo.Groups(gi);
                gPath = g.Name;
                [~, gName] = fileparts(gPath);
                if strcmp(gName, 'resources')
                    % Found a resources group — check its children
                    if isfield(g, 'Groups') && ~isempty(g.Groups)
                        for ri = 1:numel(g.Groups)
                            rg = g.Groups(ri);
                            resourcePaths{end+1} = rg.Name; %#ok<AGROW>
                        end
                    end
                else
                    % Recurse into subgroups
                    findResourceGroups(g, gPath);
                end
            end
        end
    end

    fprintf('Found %d resource entries.\n\n', numel(resourcePaths));

    for i = 1:numel(resourcePaths)
        rPath = resourcePaths{i};

        % Check if this resource is named 'propertyDescriptors'
        resName = '';
        try
            resName = deblank(char(h5readatt(h5path, rPath, 'name')));
        catch
            continue;
        end

        if ~strcmp(resName, 'propertyDescriptors')
            continue;
        end

        nScanned = nScanned + 1;
        dataPath = [rPath '/data'];

        % Read the byte stream
        try
            rawBytes = h5read(h5path, dataPath);
        catch ex
            fprintf('  SKIP %s: cannot read data (%s)\n', rPath, ex.message);
            nSkipped = nSkipped + 1;
            continue;
        end

        % Deserialize
        try
            descriptors = getArrayFromByteStream(uint8(rawBytes));
        catch ex
            fprintf('  SKIP %s: cannot deserialize (%s)\n', rPath, ex.message);
            nSkipped = nSkipped + 1;
            continue;
        end

        % Check if any descriptor has type = []
        needsFix = false;
        if isstruct(descriptors)
            % Already a struct array (from saveobj) — check type fields
            for d = 1:numel(descriptors)
                if isfield(descriptors, 'type') && isempty(descriptors(d).type)
                    needsFix = true;
                    break;
                end
            end
        elseif isa(descriptors, 'symphonyui.core.PropertyDescriptor')
            % Live object array — check type property
            for d = 1:numel(descriptors)
                if isempty(descriptors(d).type)
                    needsFix = true;
                    break;
                end
            end
        else
            fprintf('  SKIP %s: unexpected type (%s)\n', rPath, class(descriptors));
            nSkipped = nSkipped + 1;
            continue;
        end

        if ~needsFix
            fprintf('  OK   %s (%d descriptors, all types valid)\n', rPath, numel(descriptors));
            continue;
        end

        % Fix the descriptors
        nFixedHere = 0;
        if isstruct(descriptors)
            for d = 1:numel(descriptors)
                if isfield(descriptors, 'type') && isempty(descriptors(d).type)
                    descriptors(d).type = inferTypeStruct(descriptors(d).value);
                    nFixedHere = nFixedHere + 1;
                end
            end
        else
            % Convert to struct array for re-serialization using saveobj
            sArr = arrayfun(@saveobj, descriptors);
            for d = 1:numel(sArr)
                if isempty(sArr(d).type)
                    sArr(d).type = inferTypeStruct(sArr(d).value);
                    nFixedHere = nFixedHere + 1;
                end
            end
            descriptors = sArr;
        end

        fprintf('  FIX  %s (%d of %d descriptors patched)\n', rPath, nFixedHere, numel(descriptors));

        if ~dryRun
            % Re-serialize
            newBytes = getByteStreamFromArray(descriptors);

            % Write back to HDF5
            % h5write can't change dataset size, so we use low-level API
            try
                writeByteDataset(h5path, dataPath, newBytes);
                fprintf('       -> written successfully\n');
            catch writeEx
                fprintf('       -> WRITE FAILED: %s\n', writeEx.message);
                nSkipped = nSkipped + 1;
                continue;
            end
        end

        nFixed = nFixed + nFixedHere;
    end

    fprintf('\n--- Summary ---\n');
    fprintf('  Resources scanned:     %d\n', nScanned);
    fprintf('  Descriptors patched:   %d\n', nFixed);
    fprintf('  Errors/skipped:        %d\n', nSkipped);
    if dryRun && nFixed > 0
        fprintf('\n  Re-run without DryRun to apply fixes.\n');
    elseif nFixed > 0
        fprintf('\n  File patched successfully. Backup at: %s.bak\n', h5path);
    else
        fprintf('\n  No fixes needed — file is already compatible.\n');
    end
    fprintf('\n');
end

function ts = inferTypeStruct(val)
    %INFERTYPESTRUCT  Build a valid type struct from a property value.
    %   Produces {primitiveType, shape, domain} matching what Symphony 2's
    %   uiextras.jide.PropertyType expects.
    if ischar(val) || isstring(val)
        pt = 'char'; sh = 'row';
    elseif islogical(val)
        pt = 'logical'; sh = 'scalar';
    elseif isinteger(val)
        pt = 'int32'; sh = 'scalar';
    elseif iscell(val)
        pt = 'cellstr'; sh = 'row';
    else
        pt = 'denserealdouble'; sh = 'scalar';
    end
    ts = struct('primitiveType', pt, 'shape', sh, 'domain', {{}});
end

function writeByteDataset(h5path, dataPath, newBytes)
    %WRITEBYTEDATASET  Replace a uint8 dataset in an HDF5 file.
    %   Uses low-level HDF5 API to handle variable-length datasets.

    % Split path into group and dataset name
    parts = strsplit(dataPath, '/');
    dsName = parts{end};
    groupPath = strjoin(parts(1:end-1), '/');
    if isempty(groupPath)
        groupPath = '/';
    end

    fileId = H5F.open(h5path, 'H5F_ACC_RDWR', 'H5P_DEFAULT');
    cleanupFile = onCleanup(@()H5F.close(fileId));

    groupId = H5G.open(fileId, groupPath);
    cleanupGroup = onCleanup(@()H5G.close(groupId));

    % Delete old dataset and create new one with correct size
    try
        H5L.delete(groupId, dsName, 'H5P_DEFAULT');
    catch
        % Dataset may not exist; that's fine
    end

    % Create new dataset
    newBytes = uint8(newBytes(:));
    dims = numel(newBytes);
    spaceId = H5S.create_simple(1, dims, dims);
    cleanupSpace = onCleanup(@()H5S.close(spaceId));

    typeId = H5T.copy('H5T_NATIVE_UCHAR');
    cleanupType = onCleanup(@()H5T.close(typeId));

    dsetId = H5D.create(groupId, dsName, typeId, spaceId, 'H5P_DEFAULT');
    cleanupDset = onCleanup(@()H5D.close(dsetId));

    H5D.write(dsetId, 'H5ML_DEFAULT', 'H5S_ALL', 'H5S_ALL', 'H5P_DEFAULT', newBytes);
end
