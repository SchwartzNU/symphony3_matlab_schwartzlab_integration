classdef EpochGroupRelink
    % EPOCHGROUPRELINK  Move a nested epoch group to the top level (and to another
    % source) in a CLOSED Symphony file.
    %
    %   report = symphonyui.ui.EpochGroupRelink.apply(file, groupId, newSourceId)
    %
    %   An epoch group begun while another one was open is stored inside it
    %   (<parent>/epochGroups/<group> plus a 'parent' link). The core has no call
    %   to undo that, and the lab importer cannot handle such a group when its
    %   source differs from its parent's (2026-10-20, Control 7 inside Control 6).
    %   This relinks the same group object; nothing is copied or rewritten:
    %     1. experiment/epochGroups/<group>   added
    %     2. <parent>/epochGroups/<group>     removed, <group>/parent removed
    %     3. <group>/source -> new source; the group moves from the old source's
    %        epochGroups list to the new source's (when newSourceId is given)
    %   Ids are uuids with or without dashes. Each step uses a fresh handle.

    methods (Static)

        function report = apply(file, groupId, newSourceId)
            if nargin < 3, newSourceId = ''; end
            E = symphonyui.ui.EpochGroupRelink;
            report = struct('groupPath', '', 'wasNested', false, 'oldSource', '', 'newSource', '', 'steps', {{}});
            exp = E.experimentPath(file);
            [gPath, gName] = E.findGroup(file, [exp '/epochGroups'], E.norm(groupId));
            if isempty(gPath)
                error('EpochGroupRelink:notFound', 'Epoch group %s not found in %s.', groupId, file);
            end
            report.groupPath = gPath;
            top = [exp '/epochGroups/' gName];
            report.wasNested = ~strcmp(gPath, top);
            if report.wasNested
                E.rw(file, @(fid) H5L.create_hard(fid, gPath, fid, top, 'H5P_DEFAULT', 'H5P_DEFAULT'));
                E.rw(file, @(fid) H5L.delete(fid, gPath, 'H5P_DEFAULT'));
                if E.linkExists(file, [top '/parent'])
                    E.rw(file, @(fid) H5L.delete(fid, [top '/parent'], 'H5P_DEFAULT'));
                end
                report.steps{end+1} = sprintf('moved %s to the top level', gName);
            end
            if ~isempty(newSourceId)
                sources = E.allSources(file, [exp '/sources']);
                k = find(strcmp({sources.id}, E.norm(newSourceId)), 1);
                if isempty(k)
                    error('EpochGroupRelink:noSource', 'Source %s not found in %s.', newSourceId, file);
                end
                newSrc = sources(k).path;
                % old source: the one whose epochGroups list holds this group
                oldSrc = '';
                for i = 1:numel(sources)
                    if E.linkExists(file, [sources(i).path '/epochGroups/' gName])
                        oldSrc = sources(i).path;
                        break;
                    end
                end
                report.oldSource = oldSrc;
                report.newSource = newSrc;
                if ~strcmp(oldSrc, newSrc)
                    if E.linkExists(file, [top '/source'])
                        E.rw(file, @(fid) H5L.delete(fid, [top '/source'], 'H5P_DEFAULT'));
                    end
                    E.rw(file, @(fid) H5L.create_hard(fid, newSrc, fid, [top '/source'], 'H5P_DEFAULT', 'H5P_DEFAULT'));
                    if ~isempty(oldSrc)
                        E.rw(file, @(fid) H5L.delete(fid, [oldSrc '/epochGroups/' gName], 'H5P_DEFAULT'));
                    end
                    if ~E.linkExists(file, [newSrc '/epochGroups/' gName])
                        E.rw(file, @(fid) H5L.create_hard(fid, top, fid, [newSrc '/epochGroups/' gName], 'H5P_DEFAULT', 'H5P_DEFAULT'));
                    end
                    report.steps{end+1} = 'source changed';
                end
            end
        end

        % ---------------------------------------------------------------- helpers
        function s = norm(id)
            s = lower(strrep(char(string(id)), '-', ''));
        end

        function exp = experimentPath(file)
            names = symphonyui.ui.EpochGroupRelink.children(file, '/');
            k = find(startsWith(names, 'experiment-'), 1);
            if isempty(k), error('EpochGroupRelink:noExperiment', 'No experiment in %s.', file); end
            exp = ['/' names{k}];
        end

        function [path, name] = findGroup(file, container, gid)
            % breadth-first through <container>/epochGroup-*/epochGroups
            E = symphonyui.ui.EpochGroupRelink;
            path = ''; name = '';
            queue = {container};
            while ~isempty(queue)
                c = queue{1}; queue(1) = [];
                for m = E.children(file, c)
                    if ~startsWith(m{1}, 'epochGroup-'), continue; end
                    p = [c '/' m{1}];
                    if strcmp(E.norm(extractAfter(m{1}, 'epochGroup-')), gid)
                        path = p; name = m{1};
                        return;
                    end
                    queue{end+1} = [p '/epochGroups']; %#ok<AGROW>
                end
            end
        end

        function s = allSources(file, container)
            E = symphonyui.ui.EpochGroupRelink;
            s = struct('id', {}, 'path', {});
            queue = {container};
            while ~isempty(queue)
                c = queue{1}; queue(1) = [];
                for m = E.children(file, c)
                    if ~startsWith(m{1}, 'source-'), continue; end
                    p = [c '/' m{1}];
                    s(end+1) = struct('id', E.norm(extractAfter(m{1}, 'source-')), 'path', p); %#ok<AGROW>
                    queue{end+1} = [p '/sources']; %#ok<AGROW>
                end
            end
        end

        function n = children(file, path)
            n = {};
            try
                fid = H5F.open(file, 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
                c = onCleanup(@() H5F.close(fid));
                if ~strcmp(path, '/') && ~symphonyui.ui.FileCheckpoint.linkExists(fid, path)
                    return;
                end
                n = symphonyui.ui.FileCheckpoint.children(fid, path);
                n = n(:)';
            catch
            end
        end

        function tf = linkExists(file, path)
            tf = false;
            try
                fid = H5F.open(file, 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
                c = onCleanup(@() H5F.close(fid));
                tf = symphonyui.ui.FileCheckpoint.linkExists(fid, path);
            catch
            end
        end

        function rw(file, fcn)
            fid = H5F.open(file, 'H5F_ACC_RDWR', 'H5P_DEFAULT');
            c = onCleanup(@() H5F.close(fid));
            fcn(fid);
        end
    end
end
