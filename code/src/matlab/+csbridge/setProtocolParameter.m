function out = setProtocolParameter(name, value)
    %CSBRIDGE.SETPROTOCOLPARAMETER  Set a single protocol property.
    %   Returns '' to satisfy the C# nargout>=1 dispatcher.

    out = '';
    %
    %   csbridge.setProtocolParameter('preTime', 250.0)
    %   csbridge.setProtocolParameter('numberOfAverages', int32(10))
    %   csbridge.setProtocolParameter('amp', 'Amp1')
    %
    %   No-op if no protocol is selected.

    s = csbridge.State.instance();
    if isempty(s.protocol)
        return;
    end

    p = s.protocol;
    if ~isprop(p, name)
        error('csbridge:noSuchProperty', ...
            'Protocol "%s" has no property "%s"', class(p), name);
    end

    currentValue = p.(name);

    % If the target property is numeric (or logical) and the incoming
    % value is a string, parse the string as a MATLAB numeric literal.
    % This lets the C# UI accept "0:25:100", "[1 2 3]", "linspace(0,1,5)"
    % for vector-typed properties — same semantics as the legacy Java
    % MATLAB UI.
    isStringInput = ischar(value) || (isstring(value) && isscalar(value));
    isNumericTarget = isnumeric(currentValue) || islogical(currentValue);
    if isStringInput && isNumericTarget
        txt = strtrim(char(value));
        if isempty(txt)
            % Empty string → leave property unchanged (nothing to do).
            return;
        end
        parsed = str2num(txt); %#ok<ST2NM>  %ok intentional: matches Java UI behavior
        if isempty(parsed)
            error('csbridge:badNumericLiteral', ...
                'Could not parse "%s" as a numeric literal for property "%s".', ...
                txt, name);
        end
        value = parsed;
    end

    % MATLAB Engine API marshals .NET strings as MATLAB string scalars
    % and .NET doubles as MATLAB doubles, so most assignments work
    % directly. For protocol properties typed as uint16/int32 (e.g.
    % numberOfAverages), coerce numeric inputs to the property's
    % declared class so the assignment doesn't fail validation.
    try
        p.(name) = value;
    catch
        % If direct assignment fails (typically a type-class mismatch
        % from JSON deserialization quirks), try coercing to the
        % property's current class.
        if ~isempty(currentValue)
            coerced = cast(value, class(currentValue));
            p.(name) = coerced;
        else
            rethrow(MException('csbridge:setFailed', ...
                'Could not assign value to property "%s"', name));
        end
    end
end
