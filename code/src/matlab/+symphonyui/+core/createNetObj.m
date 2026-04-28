function obj = createNetObj(typeName, varargin)
    %CREATENETOBJ  Create a .NET object by type name, cross-platform.
    %
    %   obj = createNetObj('Symphony.Core.Controller')
    %   obj = createNetObj('Symphony.Core.Measurement', 5.0, 'V')
    %
    %   On Windows, MATLAB's NET namespace resolution works directly.
    %   On macOS/Linux with .NET Core/.NET 5+, namespace resolution may
    %   fail — this function falls back to System.Activator.CreateInstance.

    % Try direct MATLAB .NET syntax first (fast path, works on Windows)
    try
        if isempty(varargin)
            obj = eval([typeName '()']);
        else
            obj = eval([typeName '(varargin{:})']);
        end
        return;
    catch
    end

    % Fallback: find the type in loaded assemblies and use Activator
    try
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
            error('symphonyui:createNetObj', 'Type "%s" not found in loaded assemblies', typeName);
        end

        if isempty(varargin)
            obj = System.Activator.CreateInstance(targetType);
        else
            % Convert MATLAB args to .NET objects
            args = NET.createArray('System.Object', numel(varargin));
            for k = 1:numel(varargin)
                v = varargin{k};
                % Char arrays (esp. single-char like 'V') get boxed
                % as System.Char in Object[], failing to match
                % constructor overloads expecting System.String.
                % Converting to string scalar first routes them
                % through the bridge's System.String mapping.
                if ischar(v)
                    v = string(v);
                end
                args.Set(k-1, v);
            end
            obj = System.Activator.CreateInstance(targetType, args);
        end
    catch ex
        error('symphonyui:createNetObj', 'Failed to create "%s": %s', typeName, ex.message);
    end
end
