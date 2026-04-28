function setNetProperty(target, propertyName, value)
    %SETNETPROPERTY  Set a .NET property by name, cross-platform.
    %
    %   setNetProperty(cobj, 'SampleRate', measurement.cobj)
    %
    %   On Windows, MATLAB's direct syntax works: cobj.SampleRate = value.
    %   On macOS/Linux with .NET Core, MATLAB's property setter validates
    %   the value against the declared property type and rejects interface-
    %   typed values with MATLAB:class:RequireClass — even when the value
    %   actually implements that interface at the CLR level. This helper
    %   routes through PropertyInfo.SetValue so the CLR does the type
    %   check instead of MATLAB.

    % Fast path: direct assignment (works on Windows)
    try
        target.(propertyName) = value;
        return;
    catch
    end

    % Reflection fallback: let the CLR do the interface check
    t = target.GetType();
    prop = t.GetProperty(propertyName);
    if isempty(prop)
        error('symphonyui:setNetProperty', ...
              'Property "%s" not found on type "%s"', ...
              propertyName, char(t.FullName));
    end

    % Box MATLAB char arrays to System.String so the CLR's
    % reflection binder sees the right argument type (same trap we
    % already handled in callNetStatic/createNetObj).
    if ischar(value)
        value = string(value);
    end

    % Go directly through the setter MethodInfo rather than
    % PropertyInfo.SetValue. MATLAB's .NET Core bridge fails to find
    % any matching SetValue overload on RuntimePropertyInfo
    % ("No method 'SetValue' with matching signature found"), but
    % ordinary MethodInfo.Invoke resolves cleanly.
    setter = prop.GetSetMethod();
    if isempty(setter)
        error('symphonyui:setNetProperty', ...
              'Property "%s" on "%s" has no public setter', ...
              propertyName, char(t.FullName));
    end
    % Surface diagnostic context in the error itself so it can't be
    % missed when run from callbacks that swallow stdout.
    diag = sprintf('[setNetProperty target=%s prop=%s value=%s empty=%d]', ...
        class(target), propertyName, class(value), isempty(value));

    % Build args using the value's exact runtime type as the array
    % element type. MATLAB's bridge fails to convert arbitrary .NET
    % instances to System.Object on macOS .NET Core, but it CAN store
    % a value into an array whose element type matches the value
    % exactly (Set(int, ExactType) is unambiguous). The resulting
    % typed array is then passed to MethodInfo.Invoke; .NET's array
    % covariance handles the implicit cast to object[] server-side.
    try
        valueType = char(value.GetType().FullName);
        args = NET.createArray(valueType, 1);
        args.Set(0, value);
        setter.Invoke(target, args);
    catch ex
        error('symphonyui:setNetProperty', ...
              '%s Failed to set .NET property: %s', diag, ex.message);
    end
end
