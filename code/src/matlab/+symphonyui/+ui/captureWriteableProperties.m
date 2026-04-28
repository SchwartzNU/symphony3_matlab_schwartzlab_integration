function m = captureWriteableProperties(obj)
%CAPTUREWRITEABLEPROPERTIES  Snapshot the writeable public properties of a protocol.
%
%   m = captureWriteableProperties(obj) returns a containers.Map of
%   name -> value for every *writeable* public property of the handle
%   object `obj`. Writeable here means: visible via `properties(obj)`
%   (so non-hidden), has a meta-property with public SetAccess, and
%   is not Constant or Dependent-without-a-setter.
%
%   This is used by SymphonyApp to remember user-tweaked protocol
%   parameters within a session. It intentionally *excludes* computed
%   and read-only fields, because those can't be restored via direct
%   assignment and caching them just generates warnings later.
%
%   See also: symphonyui.ui.restoreWriteableProperties

    m = containers.Map('KeyType', 'char', 'ValueType', 'any');

    names = properties(obj);   % visible (non-hidden) public properties
    for i = 1:numel(names)
        name = names{i};
        mpo = findprop(obj, name);
        if isempty(mpo)
            continue;  % shouldn't happen for names from properties(), but guard anyway
        end
        if ~strcmp(mpo.SetAccess, 'public')
            continue;  % protected/private setters — can't restore
        end
        if mpo.Constant
            continue;
        end
        if mpo.Dependent && isempty(mpo.SetMethod)
            continue;  % computed, no setter — read-only
        end
        try
            m(name) = obj.(name);
        catch
            % A getter that throws under the current state is rare but
            % possible (e.g. pulled from a closed rig). Skip silently —
            % we'll just fall back to the protocol's class default
            % the next time this protocol is selected.
        end
    end
end
