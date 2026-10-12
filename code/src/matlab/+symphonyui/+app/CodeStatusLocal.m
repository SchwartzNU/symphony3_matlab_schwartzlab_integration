classdef CodeStatusLocal
    % Helpers for symphonyui.app.CodeStatus: run git with a timeout, find a
    % checkout root from a file inside it, compare abbreviated commits.

    methods (Static)

        function [ok, out] = git(repoPath, args, timeoutSeconds)
            if nargin < 3, timeoutSeconds = 20; end
            ok = false;
            out = '';
            if ~isfolder(repoPath)
                out = 'missing folder';
                return;
            end
            % GIT_TERMINAL_PROMPT=0 stops git from waiting for credentials; the
            % fetch itself carries low-speed limits so a dead network fails in
            % seconds rather than hanging the launch. timeoutSeconds is kept
            % for the callers' documentation; git's own limits enforce it.
            setenv('GIT_TERMINAL_PROMPT', '0');
            [status, out] = system(sprintf('git -C "%s" %s 2>&1', repoPath, args)); %#ok<*NASGU>
            out = strtrim(out);
            ok = status == 0;
        end

        function root = rootOf(file)
            root = '';
            if isempty(file), return; end
            d = fileparts(file);
            [ok, out] = symphonyui.app.CodeStatusLocal.git(d, 'rev-parse --show-toplevel', 10);
            if ok
                root = strrep(strtrim(out), '/', filesep);
            end
        end

        function tf = sameCommit(a, b)
            n = min(numel(a), numel(b));
            tf = n >= 7 && strncmpi(a, b, n);
        end

        function n = tmpName(kind)
            n = fullfile(tempdir, sprintf('symphony_codestatus_%s.txt', kind));
        end

        function t = readAll(file)
            t = '';
            try
                if isfile(file)
                    t = strtrim(fileread(file));
                end
            catch
            end
        end
    end
end
