classdef CodeStatus
    % CODESTATUS  Git state of the acquisition code, checked against GitHub.
    %
    %   s = symphonyui.app.CodeStatus.check()        fetch origin and compare (needs network)
    %   s = symphonyui.app.CodeStatus.check(false)   local state only
    %   symphonyui.app.CodeStatus.summary(s)         one line per repository
    %   symphonyui.app.CodeStatus.blocking(s)        reasons a NEW experiment must not start
    %   symphonyui.app.CodeStatus.warnings(s)        reasons to double check (dirty, ahead, no network)
    %   symphonyui.app.CodeStatus.fileProperties(s)  experiment properties recording the versions
    %
    %   Repositories: the Symphony 3 fork (this file's checkout), the sa-labs
    %   extension on the search path, and the Stage 3 testbed (StartStage.m).
    %   When the Stage PC watchdog answers a 'version' query, its own
    %   stage3_testbed and sa-labs-extension commits are included as
    %   'stagepc/<repo>' and compared with the rig's; a mismatch blocks too,
    %   because the controllers that run on the Stage PC must match the rig.
    %
    %   A repository is out of date when it is behind its upstream after a
    %   fetch (block). Uncommitted changes, unpushed commits and an
    %   unreachable GitHub are warnings: they are written into the file so
    %   the record is honest, and the user confirms.

    methods (Static)

        function s = check(fetch)
            if nargin < 1, fetch = true; end
            import symphonyui.app.CodeStatus
            repos = CodeStatus.repos();
            s = repmat(CodeStatus.emptyStatus(), 1, 0);
            for i = 1:numel(repos)
                s(end+1) = CodeStatus.checkRepo(repos(i), fetch); %#ok<AGROW>
            end
            s = [s, CodeStatus.stagePcStatus(s)];
        end

        function repos = repos()
            repos = struct('name', {}, 'path', {}, 'expectedBranch', {});
            fork = symphonyui.app.CodeStatusLocal.rootOf(which('addAppPaths'));
            if ~isempty(fork)
                repos(end+1) = struct('name', 'symphony3_matlab', 'path', fork, 'expectedBranch', 'master');
            end
            ext = symphonyui.app.CodeStatusLocal.rootOf(which('sa_labs.protocols.BaseProtocol'));
            if ~isempty(ext)
                repos(end+1) = struct('name', 'sa-labs-extension', 'path', ext, 'expectedBranch', 'symphony3-port');
            end
            % StartStage.m sits at the stage-matlab root, which is not on the path;
            % anchor on a class from stage-matlab/src/main/matlab instead
            stage = symphonyui.app.CodeStatusLocal.rootOf(which('stage.core.network.StageClient'));
            if ~isempty(stage)
                repos(end+1) = struct('name', 'stage3_testbed', 'path', stage, 'expectedBranch', 'master');
            end
        end

        function r = checkRepo(repo, fetch)
            import symphonyui.app.CodeStatus
            r = CodeStatus.emptyStatus();
            r.name = repo.name;
            r.path = repo.path;
            r.expectedBranch = repo.expectedBranch;
            [ok, out] = symphonyui.app.CodeStatusLocal.git(repo.path, 'rev-parse --abbrev-ref HEAD');
            if ~ok
                r.error = ['not a git checkout: ' out];
                return;
            end
            r.branch = out;
            [ok, out] = symphonyui.app.CodeStatusLocal.git(repo.path, 'rev-parse --short=10 HEAD');
            if ok, r.commit = out; end
            [ok, out] = symphonyui.app.CodeStatusLocal.git(repo.path, 'status --porcelain --untracked-files=no');
            if ok, r.dirty = ~isempty(out); end
            [ok, out] = symphonyui.app.CodeStatusLocal.git(repo.path, 'rev-parse --abbrev-ref @{u}');
            if ok
                r.upstream = out;
            else
                r.error = 'no upstream branch';
                return;
            end
            if fetch
                % keep a dead network from hanging the launch: give up after ~10 s
                [ok, out] = symphonyui.app.CodeStatusLocal.git(repo.path, ...
                    '-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 fetch --quiet origin', 45);
                r.fetched = ok;
                if ~ok
                    r.error = ['fetch failed: ' strtrim(out)];
                end
            end
            [ok, out] = symphonyui.app.CodeStatusLocal.git(repo.path, 'rev-list --count HEAD..@{u}');
            if ok, r.behind = str2double(out); end
            [ok, out] = symphonyui.app.CodeStatusLocal.git(repo.path, 'rev-list --count @{u}..HEAD');
            if ok, r.ahead = str2double(out); end
        end

        function s = stagePcStatus(local)
            % 'stagepc/<repo>' entries from the Stage PC watchdog ('version'
            % command); empty when the watchdog is unreachable or too old.
            import symphonyui.app.CodeStatus
            s = repmat(CodeStatus.emptyStatus(), 1, 0);
            reply = '';
            try
                if ~isempty(which('restartStageServer'))
                    reply = evalc('restartStageServer(''version'')');
                end
            catch
                return;
            end
            reply = strtrim(reply);
            if ~startsWith(reply, 'ok ')
                return;
            end
            % ok stage3_testbed=master@602d67d:0 sa-labs-extension=symphony3-port@1d4eae2:0
            tok = regexp(reply, '(\S+)=(\S+)@([0-9a-f]+):(\d+)', 'tokens');
            for i = 1:numel(tok)
                r = CodeStatus.emptyStatus();
                r.name = ['stagepc/' tok{i}{1}];
                r.path = '192.168.0.3';
                r.branch = tok{i}{2};
                r.commit = tok{i}{3};
                r.dirty = str2double(tok{i}{4}) > 0;
                r.fetched = true;
                % compare with the rig's checkout of the same repository
                k = find(strcmp({local.name}, tok{i}{1}), 1);
                if ~isempty(k)
                    r.expectedBranch = local(k).branch;
                    if ~symphonyui.app.CodeStatusLocal.sameCommit(r.commit, local(k).commit)
                        r.mismatch = sprintf('Stage PC has %s, this rig has %s', r.commit, local(k).commit);
                    end
                end
                s(end+1) = r; %#ok<AGROW>
            end
        end

        function reasons = blocking(s)
            reasons = {};
            for i = 1:numel(s)
                r = s(i);
                if r.behind > 0
                    reasons{end+1} = sprintf('%s is %d commit(s) behind %s (git pull)', r.name, r.behind, r.upstream); %#ok<AGROW>
                end
                if ~isempty(r.mismatch)
                    reasons{end+1} = sprintf('%s: %s (update the Stage PC and restart its server)', r.name, r.mismatch); %#ok<AGROW>
                end
                if ~isempty(r.expectedBranch) && ~isempty(r.branch) && ~strcmp(r.branch, r.expectedBranch) && ~startsWith(r.name, 'stagepc/')
                    reasons{end+1} = sprintf('%s is on branch %s, expected %s', r.name, r.branch, r.expectedBranch); %#ok<AGROW>
                end
            end
        end

        function reasons = warnings(s)
            reasons = {};
            for i = 1:numel(s)
                r = s(i);
                if ~isempty(r.error)
                    reasons{end+1} = sprintf('%s: %s (GitHub not checked)', r.name, r.error); %#ok<AGROW>
                end
                if r.dirty
                    reasons{end+1} = sprintf('%s has uncommitted changes', r.name); %#ok<AGROW>
                end
                if r.ahead > 0
                    reasons{end+1} = sprintf('%s has %d commit(s) not pushed to %s', r.name, r.ahead, r.upstream); %#ok<AGROW>
                end
            end
        end

        function t = summary(s)
            lines = cell(1, numel(s));
            for i = 1:numel(s)
                r = s(i);
                state = 'current';
                if r.behind > 0, state = sprintf('BEHIND by %d', r.behind); end
                if ~isempty(r.mismatch), state = 'MISMATCH'; end
                extra = '';
                if r.dirty, extra = [extra ' dirty']; end
                if r.ahead > 0, extra = [extra sprintf(' ahead %d', r.ahead)]; end
                if ~r.fetched && isempty(r.mismatch), extra = [extra ' (not fetched)']; end
                if ~isempty(r.error), extra = [extra ' ' r.error]; end
                lines{i} = sprintf('%-28s %s@%s  %s%s', r.name, r.branch, r.commit, state, extra);
            end
            t = strjoin(lines, newline);
        end

        function tf = allowsNewExperiment(s)
            tf = isempty(symphonyui.app.CodeStatus.blocking(s));
        end

        function m = fileProperties(s)
            % Experiment properties recording the code versions, one per
            % repository: codeVersion_<repo> = '<branch>@<commit> ahead=<n> dirty=<0|1>'
            % plus codeVersion_checkedAt. Parsed by the DataJoint importer
            % (sln_symphony.ExperimentCodeVersion).
            m = containers.Map();
            for i = 1:numel(s)
                r = s(i);
                if isempty(r.commit), continue; end
                key = ['codeVersion_' regexprep(r.name, '[^A-Za-z0-9]', '_')];
                m(key) = sprintf('%s@%s ahead=%d dirty=%d', r.branch, r.commit, max(0, r.ahead), double(r.dirty));
            end
            m('codeVersion_checkedAt') = datestr(now, 'yyyy-mm-dd HH:MM:SS');
        end

        function r = emptyStatus()
            r = struct('name', '', 'path', '', 'expectedBranch', '', 'branch', '', 'commit', '', ...
                'upstream', '', 'dirty', false, 'ahead', 0, 'behind', 0, 'fetched', false, ...
                'mismatch', '', 'error', '');
        end
    end
end
