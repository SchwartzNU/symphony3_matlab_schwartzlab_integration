function paths = getSearchPaths()
    %CSBRIDGE.GETSEARCHPATHS  Default search paths for rig/protocol discovery.
    %
    %   Mirrors SymphonyApp.getSearchPaths() — reads the user's
    %   Options.searchPath preference (if any) plus the bundled
    %   examples directory. The C# UI calls this so its discover-
    %   rigs/protocols pipeline finds the same packages the MATLAB
    %   UI would.

    paths = {};

    % User-configured search paths from app Options (semicolon-delimited)
    try
        opts = symphonyui.app.Options.getDefault();
        sp = opts.searchPath;
        if isa(sp, 'function_handle'), sp = sp(); end
        sp = char(sp);
        if ~isempty(sp)
            parts = strsplit(sp, {';', pathsep});
            for i = 1:numel(parts)
                p = strtrim(parts{i});
                if ~isempty(p) && exist(p, 'dir') == 7
                    paths{end+1} = p; %#ok<AGROW>
                end
            end
        end
    catch
        % Options may not be configured — fall through to defaults
    end

    % Bundled examples directory
    appDir = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
    examples = fullfile(appDir, 'code', 'src', 'resources', 'examples');
    if exist(examples, 'dir') == 7
        paths{end+1} = examples;
    end

    % MATLAB's own path is also a valid place for user packages —
    % include any directory that already contains a +rigs or +protocols
    % subfolder. This is the common case for users who simply put
    % their `test-package` (or similar) on MATLAB's path.
    try
        for d = strsplit(path, pathsep)
            entry = strtrim(d{1});
            if isempty(entry), continue; end
            if exist(fullfile(entry, '+rigs'), 'dir') == 7 ...
                    || exist(fullfile(entry, '+protocols'), 'dir') == 7 ...
                    || ~isempty(dir(fullfile(entry, '+*', '+rigs')))
                if ~any(strcmp(paths, entry))
                    paths{end+1} = entry; %#ok<AGROW>
                end
            end
        end
    catch
    end
end
