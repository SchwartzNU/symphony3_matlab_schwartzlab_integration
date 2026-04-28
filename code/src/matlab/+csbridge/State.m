classdef State < handle
    %CSBRIDGE.STATE  Singleton holding rig/protocol state for the C# UI.
    %
    %   The C# UI is a separate process that drives Symphony through
    %   MATLAB Engine API. Each call into MATLAB is stateless from the
    %   .NET side — it gives us a name (a class name) or a value, and
    %   we use this singleton to remember "what's the current rig" /
    %   "what's the current protocol" between calls.
    %
    %   Usage (from any csbridge.* function):
    %       s = csbridge.State.instance();
    %       s.rig = aRig;
    %       protocol = s.protocol;

    properties
        rig         % symphonyui.core.Rig or []
        protocol    % symphonyui.core.Protocol or []
    end

    methods (Static)
        function obj = instance()
            persistent inst
            if isempty(inst) || ~isvalid(inst)
                inst = csbridge.State();
            end
            obj = inst;
        end

        function reset()
            % For tests — drops the cached singleton so the next
            % instance() call creates a fresh State.
            inst = csbridge.State.instance();
            try, if ~isempty(inst.rig), inst.rig.close(); end, catch, end
            try, if ~isempty(inst.protocol), inst.protocol.close(); end, catch, end
            inst.rig = [];
            inst.protocol = [];
        end
    end

    methods (Access = private)
        function obj = State()
            obj.rig = [];
            obj.protocol = [];
        end
    end
end
