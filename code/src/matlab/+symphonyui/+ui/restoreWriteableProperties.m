function failures = restoreWriteableProperties(obj, map)
%RESTOREWRITEABLEPROPERTIES  Apply a cached property map to a protocol instance.
%
%   failures = restoreWriteableProperties(obj, map) iterates `map`
%   (containers.Map of name -> value) and assigns each entry to the
%   corresponding property of `obj`. Each assignment is done directly
%   (obj.(name) = value), bypassing Protocol.setProperty's strict
%   PropertyType check — that check fails whenever a property lacks an
%   `*Type` companion, even though the assignment itself would work.
%
%   Per-property failures are collected and returned as a struct array
%   with fields `name` and `message`. The caller decides what to do
%   with them (typically log a warning). A single failure never aborts
%   the remaining assignments.
%
%   Expected failure modes that are absorbed gracefully:
%     * property removed from the class since the cache was written
%     * SetAccess tightened to protected/private
%     * type constraint the assignment itself violates (e.g. cached
%       device name not present on the current rig)
%     * Dependent property with no setter
%
%   See also: symphonyui.ui.captureWriteableProperties

    failures = struct('name', {}, 'message', {});

    if isempty(map) || map.Count == 0
        return;
    end

    names = map.keys;
    for i = 1:numel(names)
        name = names{i};
        value = map(name);

        mpo = findprop(obj, name);
        if isempty(mpo)
            failures(end + 1) = struct( ...
                'name', name, ...
                'message', 'property no longer exists on the class');
            continue;
        end
        if ~strcmp(mpo.SetAccess, 'public')
            failures(end + 1) = struct( ...
                'name', name, ...
                'message', 'property is no longer publicly settable');
            continue;
        end
        if mpo.Constant
            failures(end + 1) = struct( ...
                'name', name, ...
                'message', 'property is Constant');
            continue;
        end
        if mpo.Dependent && isempty(mpo.SetMethod)
            failures(end + 1) = struct( ...
                'name', name, ...
                'message', 'property is Dependent with no setter');
            continue;
        end

        try
            obj.(name) = value;
        catch assignEx
            failures(end + 1) = struct( ...
                'name', name, ...
                'message', assignEx.message);
        end
    end
end
