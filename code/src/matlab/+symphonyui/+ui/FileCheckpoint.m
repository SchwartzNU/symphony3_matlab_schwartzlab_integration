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
            m = 'run';
            try
                m = char(getpref('SymphonyUI', 'fileCheckpoint', 'run'));
            catch
            end
            if ~any(strcmp(m, {'run', 'epochGroup', 'off'}))
                m = 'run';
            end
        end

        function ok = run(host, reason)
            % RUN  Checkpoint the file now. REASON is 'run' (a recorded run
            % finished) or 'epochGroup' (an epoch group was ended). Returns
            % true when the file was closed and reopened.
            ok = false;
            if nargin < 2, reason = 'run'; end
            mode = symphonyui.ui.FileCheckpoint.getMode();
            if strcmp(mode, 'off') || (strcmp(mode, 'epochGroup') && ~strcmp(reason, 'epochGroup'))
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
