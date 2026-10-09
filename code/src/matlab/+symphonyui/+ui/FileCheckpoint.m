classdef FileCheckpoint
    % FILECHECKPOINT  Commit the open Symphony 3 data file to disk without ending its epoch groups.
    %
    %   The C# persistor only writes HDF5 metadata when the file is closed, and
    %   exposes no flush, so a MATLAB crash loses every epoch group, block and
    %   epoch recorded since the file was created (seen on Rig A, 2026-10-08).
    %   A checkpoint closes the HDF5 document (H5EpochPersistor.CloseDocument,
    %   which unlike Close leaves the open epoch groups open), reopens the file
    %   through the acquisition host, and resumes the open epoch groups by label,
    %   outermost first. Afterwards the loss from a crash is bounded by the
    %   current run.
    %
    %   When it runs is a preference:
    %       setpref('SymphonyUI', 'fileCheckpoint', 'run')          after every recorded run and
    %                                                               at epoch-group end (default)
    %       setpref('SymphonyUI', 'fileCheckpoint', 'epochGroup')   only when an epoch group ends
    %       setpref('SymphonyUI', 'fileCheckpoint', 'off')
    %
    %   Callers must drop any MATLAB Persistor wrapper of the old C# persistor
    %   (SymphonyApp.getFilePersistor re-validates its cache) and refresh the
    %   Data Manager.

    methods (Static)

        function n = writeSourceLinks(path)
            % WRITESOURCELINKS  Add the source links that H5EpochPersistor.Close writes.
            %   The persistor stores each source group under the first epoch
            %   group that used it ('.../epochGroups/<g>/source', parents as
            %   '.../source/parent') and, only in Close(), adds soft links
            %   '/experiment/sources/source-<uuid>' for root sources and
            %   '<parent>/sources/source-<uuid>' for children. Readers (the
            %   acquisition host, the lab's importer) enumerate sources through
            %   those links, so a file that was checkpointed (CloseDocument) or
            %   never closed shows no sources. This writes any missing link,
            %   never touches data, and is a no-op on a normally closed file.
            %   The file must not be open elsewhere. Returns the number added.
            n = 0;
            % Discovery on a read-only handle: once the library trips over a
            % truncated object (an epoch group left half-written by a crash),
            % every later call on that handle fails, so the links are created
            % afterwards on a fresh read-write handle that never touches the
            % damaged object.
            fid = H5F.open(path, 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
            cf = onCleanup(@() symphonyui.ui.FileCheckpoint.closeQuietly(fid));
            todo = {};   % rows: {container, linkName, target}
            exps = symphonyui.ui.FileCheckpoint.children(fid, '/');
            exps = exps(startsWith(exps, 'experiment-'));
            for e = 1:numel(exps)
                expPath = ['/' exps{e}];
                % every epoch group, recursively
                groups = {};
                queue = {[expPath '/epochGroups']};
                while ~isempty(queue)
                    base = queue{1}; queue(1) = [];
                    if ~symphonyui.ui.FileCheckpoint.linkExists(fid, base), continue; end
                    kids = symphonyui.ui.FileCheckpoint.children(fid, base);
                    for k = 1:numel(kids)
                        if startsWith(kids{k}, 'epochGroup-')
                            gp = [base '/' kids{k}];
                            groups{end+1} = gp; %#ok<AGROW>
                            queue{end+1} = [gp '/epochGroups']; %#ok<AGROW>
                        end
                    end
                end
                % sources reachable from those groups: path and parent path by uuid
                srcPath = containers.Map();      % uuid -> path
                srcParent = containers.Map();    % uuid -> parent uuid ('' for roots)
                for g = 1:numel(groups)
                    sp = [groups{g} '/source'];
                    while symphonyui.ui.FileCheckpoint.linkExists(fid, sp)
                        uuid = symphonyui.ui.FileCheckpoint.uuidOf(path, sp);
                        if isempty(uuid), break; end
                        pp = [sp '/parent'];
                        hasParent = symphonyui.ui.FileCheckpoint.linkExists(fid, pp);
                        if ~srcPath.isKey(uuid)
                            srcPath(uuid) = sp;
                            if hasParent
                                srcParent(uuid) = symphonyui.ui.FileCheckpoint.uuidOf(path, pp);
                            else
                                srcParent(uuid) = '';
                            end
                        end
                        if ~hasParent, break; end
                        sp = pp;
                    end
                end
                % add the missing links
                ids = keys(srcPath);
                for i = 1:numel(ids)
                    uuid = ids{i};
                    if isempty(srcParent(uuid))
                        container = [expPath '/sources'];
                    else
                        container = [srcPath(srcParent(uuid)) '/sources'];
                    end
                    if ~symphonyui.ui.FileCheckpoint.linkExists(fid, container), continue; end
                    linkName = ['source-' uuid];
                    if symphonyui.ui.FileCheckpoint.linkExists(fid, [container '/' linkName]), continue; end
                    todo(end+1, :) = {container, linkName, srcPath(uuid)}; %#ok<AGROW>
                end
            end
            clear cf;
            if isempty(todo)
                return;
            end
            fid = H5F.open(path, 'H5F_ACC_RDWR', 'H5P_DEFAULT');
            cf2 = onCleanup(@() symphonyui.ui.FileCheckpoint.closeQuietly(fid)); %#ok<NASGU>
            for i = 1:size(todo, 1)
                gid = H5G.open(fid, todo{i, 1});
                H5L.create_soft(todo{i, 3}, gid, todo{i, 2}, 'H5P_DEFAULT', 'H5P_DEFAULT');
                H5G.close(gid);
                n = n + 1;
            end
            fprintf('File checkpoint: wrote %d source link(s) in %s\n', n, path);
        end

        function closeQuietly(fid)
            try
                H5F.close(fid);
            catch
            end
        end

        function tf = linkExists(fid, path)
            % H5L.exists errors when an intermediate component is missing, so
            % walk the path one component at a time.
            tf = true;
            parts = strsplit(path, '/');
            parts = parts(~cellfun(@isempty, parts));
            cur = '';
            for i = 1:numel(parts)
                cur = [cur '/' parts{i}]; %#ok<AGROW>
                try
                    ok = H5L.exists(fid, cur, 'H5P_DEFAULT');
                catch
                    % An object whose header was never completed (e.g. the
                    % epoch group in progress when MATLAB crashed) makes the
                    % library error here; treat it as absent and move on.
                    fprintf(2, 'File checkpoint: unreadable HDF5 object skipped: %s\n', cur);
                    tf = false;
                    return;
                end
                if ~ok
                    tf = false;
                    return;
                end
            end
        end

        function names = children(fid, groupPath)
            % Names of the links in a group (no recursion).
            names = {};
            gid = H5G.open(fid, groupPath);
            cg = onCleanup(@() H5G.close(gid));
            info = H5G.get_info(gid);
            for i = 0:double(info.nlinks) - 1
                names{end+1} = H5L.get_name_by_idx(fid, groupPath, 'H5_INDEX_NAME', 'H5_ITER_NATIVE', i, 'H5P_DEFAULT'); %#ok<AGROW>
            end
        end

        function u = uuidOf(path, groupPath)
            u = '';
            try
                u = char(h5readatt(path, groupPath, 'uuid'));
            catch
            end
        end

        function setPath(p)
            setappdata(groot, 'SymphonyFileCheckpointPath', char(p));
        end

        function p = getPath()
            p = '';
            try
                p = getappdata(groot, 'SymphonyFileCheckpointPath');
                if isempty(p), p = ''; end
            catch
            end
        end

        function m = getMode()
            % 'flush' (default): H5Fflush at every commit point and periodically
            % during runs; 'reopen': the older close/reopen checkpoint; 'off'.
            m = 'flush';
            try
                m = char(getpref('SymphonyUI', 'fileCheckpoint', 'flush'));
            catch
            end
            if ~any(strcmp(m, {'flush', 'reopen', 'off'}))
                m = 'flush';
            end
        end

        function ok = flushPersistor(cper, reason)
            % FLUSHPERSISTOR  H5Fflush the persistor's file through the core's own
            % HDF5 instance (HDF.PInvoke loads hdf5_symphony.dll, the library the
            % persistor writes with), under the persistor's HDF5 lock so it never
            % races the writer thread. Afterwards everything written so far,
            % including the open epoch group and block, is on disk in a
            % consistent state: a hard kill right after a flush loses nothing
            % (verified 2026-10-08). Returns true on success.
            persistent flushMethod scopeGlobal
            ok = false;
            if nargin < 2, reason = ''; end
            if isempty(cper), return; end
            try
                if cper.IsClosed, return; end
            catch
            end
            try
                if isempty(flushMethod)
                    asm = [];
                    asms = System.AppDomain.CurrentDomain.GetAssemblies();
                    for i = 1:asms.Length
                        if strcmp(char(asms(i).GetName().Name), 'HDF.PInvoke')
                            asm = asms(i);
                            break;
                        end
                    end
                    if isempty(asm)
                        core = fileparts(which('HDF.PInvoke.dll'));
                        asm = NET.addAssembly(fullfile(core, 'HDF.PInvoke.dll')).AssemblyHandle;
                    end
                    t = asm.GetType('HDF.PInvoke.H5F');
                    flushMethod = t.GetMethod('flush');
                    scopeGlobal = System.Enum.ToObject(asm.GetType('HDF.PInvoke.H5F+scope_t'), int32(1));
                end
                flags = System.Enum.ToObject(System.Type.GetType('System.Reflection.BindingFlags'), int32(36));
                h5 = cper.GetType().GetField('_file', flags).GetValue(cper);
                fid = int64(h5.Fid);
                args = NET.createArray('System.Object', 2);
                args(1) = fid;
                args(2) = scopeGlobal;
                cper.AcquireLock();
                try
                    r = flushMethod.Invoke([], args);
                    cper.ReleaseLock();
                catch ex
                    cper.ReleaseLock();
                    rethrow(ex);
                end
                ok = int32(r) >= 0;
                if ~ok
                    fprintf(2, 'File flush (%s): H5Fflush returned %d\n', reason, int32(r));
                end
            catch ex
                fprintf(2, 'File flush failed (%s): %s\n', reason, ex.message);
            end
        end

        function ok = flush(host, reason)
            % FLUSH  flushPersistor for the host's current file (no-op without one).
            ok = false;
            if nargin < 2, reason = ''; end
            try
                if isempty(host) || ~logical(host.HasOpenFileAsync().GetAwaiter().GetResult())
                    return;
                end
                ok = symphonyui.ui.FileCheckpoint.flushPersistor(host.GetPersistor(), reason);
            catch ex
                fprintf(2, 'File flush failed (%s): %s\n', reason, ex.message);
            end
        end

        function ok = run(host, reason)
            % RUN  Commit the file now. REASON is 'run' (a recorded run finished),
            % 'epochGroup' (an epoch group began or ended) or 'source' (a source
            % was added). Default: an H5Fflush (see flushPersistor), which keeps
            % the file open and the epoch groups as they are. The older
            % close/reopen checkpoint remains available with
            % setpref('SymphonyUI','fileCheckpoint','reopen') and returns true
            % when the file was reopened (callers then refresh the Data Manager).
            ok = false;
            if nargin < 2, reason = 'run'; end
            mode = symphonyui.ui.FileCheckpoint.getMode();
            if strcmp(mode, 'off')
                return;
            end
            if ~strcmp(mode, 'reopen')
                symphonyui.ui.FileCheckpoint.flush(host, reason);
                return;   % nothing was reopened
            end
            if strcmp(reason, 'source')
                return;
            end
            try
                if isempty(host) || ~logical(host.HasOpenFileAsync().GetAwaiter().GetResult())
                    return;
                end
                cper = host.GetPersistor();
                if isempty(cper) || cper.IsClosed
                    return;
                end
                path = symphonyui.ui.FileCheckpoint.getPath();
                if isempty(path) || ~isfile(path)
                    fprintf(2, 'File checkpoint skipped: data file path unknown (%s)\n', path);
                    return;
                end

                % Open epoch groups, outermost first.
                labels = {};
                g = cper.CurrentEpochGroup;
                while ~isempty(g)
                    labels = [{char(g.Label)}, labels]; %#ok<AGROW>
                    g = g.Parent;
                end

                t = tic;
                cper.CloseDocument();
                % Close() is what writes the /sources links the reader needs to
                % enumerate sources; CloseDocument does not, so write them here
                % (identical layout to a normally closed file).
                try
                    symphonyui.ui.FileCheckpoint.writeSourceLinks(path);
                catch ex2
                    fprintf(2, 'File checkpoint: could not write source links: %s\n', ex2.message);
                end
                host.OpenFileAsync(path).GetAwaiter().GetResult();
                cper2 = host.GetPersistor();
                for i = 1:numel(labels)
                    cper2.ResumeEpochGroup(labels{i});
                end
                ok = true;
                if isempty(labels)
                    groups = 'no open epoch group';
                else
                    groups = ['resumed ' strjoin(labels, ' > ')];
                end
                fprintf('File checkpoint (%s): %s committed, %s (%.1f s)\n', reason, path, groups, toc(t));
            catch ex
                fprintf(2, 'File checkpoint failed (%s): %s\n', reason, ex.message);
            end
        end

    end
end
