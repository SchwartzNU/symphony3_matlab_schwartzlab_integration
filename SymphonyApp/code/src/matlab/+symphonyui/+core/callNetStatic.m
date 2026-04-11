function result = callNetStatic(typeName, methodName, varargin)
    %CALLNETSTATIC  Call a static .NET method by type name, cross-platform.
    %
    %   result = callNetStatic('Symphony.Core.Measurement', 'FromArray', data, units)
    %   result = callNetStatic('Symphony.Core.Measurement', 'ToQuantityArray', cdata)
    %
    %   On Windows, MATLAB's direct syntax works: Symphony.Core.Measurement.FromArray(...)
    %   On macOS/Linux with .NET Core, namespace resolution may fail.
    %   This function resolves the type from loaded assemblies and invokes
    %   the method via reflection.

    % Try direct MATLAB .NET syntax first (fast path)
    try
        if isempty(varargin)
            result = eval([typeName '.' methodName '()']);
        else
            argStr = 'varargin{1}';
            for k = 2:numel(varargin)
                argStr = [argStr, sprintf(', varargin{%d}', k)]; %#ok<AGROW>
            end
            result = eval([typeName '.' methodName '(' argStr ')']);
        end
        return;
    catch
    end

    % Fallback: resolve type and invoke via reflection
    assemblies = System.AppDomain.CurrentDomain.GetAssemblies();
    targetType = [];
    for i = 0:assemblies.Length-1
        asm = assemblies.Get(i);
        t = asm.GetType(typeName);
        if ~isempty(t)
            targetType = t;
            break;
        end
    end

    if isempty(targetType)
        error('symphonyui:callNetStatic', 'Type "%s" not found in loaded assemblies', typeName);
    end

    % Build argument array
    if isempty(varargin)
        args = NET.createArray('System.Object', 0);
    else
        args = NET.createArray('System.Object', numel(varargin));
        for k = 1:numel(varargin)
            args.Set(k-1, varargin{k});
        end
    end

    % Find and invoke the method
    method = targetType.GetMethod(methodName);
    if isempty(method)
        error('symphonyui:callNetStatic', 'Method "%s" not found on type "%s"', methodName, typeName);
    end

    result = method.Invoke([], args);
end
