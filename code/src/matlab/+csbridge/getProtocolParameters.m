function json = getProtocolParameters()
    %CSBRIDGE.GETPROTOCOLPARAMETERS  Return JSON list of editable protocol params.
    %
    %   Output is a JSON array of objects:
    %     [{"name":"preTime","displayName":"Pre-time (ms)",
    %       "currentValue":500,"typeHint":"double"}, ...]
    %
    %   Filters out:
    %     - Hidden, Constant, Dependent, Transient properties
    %     - Properties whose set is not public
    %     - Properties beginning with 'sampleRate'/'sampleRateType' that
    %       are inherited from Protocol base (set by didSetRig — not
    %       user-editable)

    s = csbridge.State.instance();
    if isempty(s.protocol)
        json = '[]';
        return;
    end

    p = s.protocol;
    mc = metaclass(p);
    items = struct('name', {}, 'displayName', {}, 'currentValue', {}, 'typeHint', {});

    for i = 1:numel(mc.PropertyList)
        prop = mc.PropertyList(i);
        if prop.Hidden || prop.Constant || prop.Dependent || prop.Transient
            continue;
        end
        if ~strcmp(prop.SetAccess, 'public')
            continue;
        end
        if any(strcmp(prop.Name, {'sampleRate', 'sampleRateType'}))
            continue;
        end

        currentValue = p.(prop.Name);
        items(end+1) = struct( ...
            'name', prop.Name, ...
            'displayName', describeFromComment(prop), ...
            'currentValue', encodeValue(currentValue), ...
            'typeHint', typeHintFor(currentValue)); %#ok<AGROW>
    end

    if isempty(items)
        json = '[]';
    else
        json = jsonencode(items);
    end
end


function s = describeFromComment(prop)
    % Use the property's first comment line as display name, falling
    % back to the property name itself.
    if ~isempty(prop.Description)
        s = prop.Description;
    else
        s = prop.Name;
    end
end


function v = encodeValue(x)
    % JSON can hold numbers, strings, booleans, null. Anything weirder
    % (cells, structs, .NET handles) gets stringified for now.
    if isempty(x)
        v = [];
    elseif isnumeric(x) && isscalar(x)
        v = double(x);
    elseif islogical(x) && isscalar(x)
        v = logical(x);
    elseif ischar(x)
        v = string(x);
    elseif isstring(x) && isscalar(x)
        v = x;
    else
        try
            v = string(mat2str(x));
        catch
            v = "<unencodable>";
        end
    end
end


function t = typeHintFor(x)
    % Distinguish scalar from non-scalar numerics so the C# UI can
    % render scalars as NumericUpDown and arrays as a free-form
    % TextBox (interpreted by MATLAB via str2num — accepts colon
    % range, bracketed list, linspace, etc., matching the Java UI).
    if isempty(x)
        t = "string";
    elseif islogical(x) && isscalar(x)
        t = "bool";
    elseif isinteger(x) && isscalar(x)
        t = "int";
    elseif isnumeric(x) && isscalar(x)
        t = "double";
    elseif isinteger(x)
        t = "int[]";
    elseif isnumeric(x)
        t = "double[]";
    elseif ischar(x) || isstring(x)
        t = "string";
    else
        t = "string";
    end
end
