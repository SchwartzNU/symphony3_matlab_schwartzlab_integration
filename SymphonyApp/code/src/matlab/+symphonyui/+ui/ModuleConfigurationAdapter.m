classdef ModuleConfigurationAdapter < handle
    %MODULECONFIGURATIONADAPTER  Lightweight adapter providing the
    %   configurationService API that modules expect, backed by a live Rig.
    %   This avoids needing the full legacy SymphonyLegacyContext.

    events
        InitializedRig
    end

    properties (Access = private)
        rig  % symphonyui.core.Rig
    end

    methods

        function obj = ModuleConfigurationAdapter(rig)
            obj.rig = rig;
        end

        function setRig(obj, rig)
            obj.rig = rig;
            notify(obj, 'InitializedRig');
        end

        function d = getOutputDevices(obj)
            if isempty(obj.rig)
                d = {};
            else
                d = obj.rig.getOutputDevices();
            end
        end

        function d = getInputDevices(obj)
            if isempty(obj.rig)
                d = {};
            else
                d = obj.rig.getInputDevices();
            end
        end

        function d = getDevices(obj, name)
            if isempty(obj.rig)
                d = {};
            elseif nargin < 2
                d = obj.rig.getDevices();
            else
                d = obj.rig.getDevices(name);
            end
        end

        function d = getDevice(obj, name)
            if isempty(obj.rig)
                error('No rig initialized');
            end
            d = obj.rig.getDevice(name);
        end

    end

end
