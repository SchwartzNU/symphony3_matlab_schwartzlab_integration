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
            v = varargin{k};
            % Convert MATLAB char arrays to string scalars so the .NET
            % bridge boxes them as System.String. A bare MATLAB char
            % (esp. a 1-char array like 'V') gets boxed as System.Char
            % when placed into System.Object[], which then fails to
            % match overloads expecting System.String.
            if ischar(v)
                v = string(v);
            end
            args.Set(k-1, v);
        end
    end

    % `GetMethod(name)` without a parameter-type array throws
    % AmbiguousMatchException when multiple overloads exist (e.g.
    % Symphony.Core.ConvertProcs.Scale has both (double, string) and
    % (double, IMeasurement) overloads). Enumerate static methods of
    % matching name + arity, try each in order, and rethrow the last
    % failure if none accept the arguments. The `Invoke` call will
    % reject incompatible types with ArgumentException, so this safely
    % falls through to the right overload.
    methods = targetType.GetMethods();
    candidates = {};
    for i = 0:methods.Length-1
        m = methods.Get(i);
        if strcmp(char(m.Name), methodName) && m.IsStatic && ...
                double(m.GetParameters().Length) == numel(varargin)
            candidates{end+1} = m; %#ok<AGROW>
        end
    end

    if isempty(candidates)
        error('symphonyui:callNetStatic', ...
              'No static method "%s" with %d parameter(s) found on "%s"', ...
              methodName, numel(varargin), typeName);
    end

    if numel(candidates) == 1
        result = candidates{1}.Invoke([], args);
        return;
    end

    lastEx = [];
    for i = 1:numel(candidates)
        try
            result = candidates{i}.Invoke([], args);
            return;
        catch ex
            lastEx = ex;
        end
    end
    rethrow(lastEx);
end
