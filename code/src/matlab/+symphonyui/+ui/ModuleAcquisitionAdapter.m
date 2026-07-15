classdef ModuleAcquisitionAdapter < handle
    %MODULEACQUISITIONADAPTER  Minimal acquisition service handed to modules.
    %   Modules in this fork are otherwise given only a configuration adapter.
    %   This lets a module (e.g. sa_labs.modules.CommonControl) push a property
    %   map onto the app's current protocol via its "Apply to Protocol" action.
    %   It simply forwards to SymphonyApp.applyProtocolPropertyMap, which sets
    %   the properties on the live MATLAB protocol and refreshes the UI.

    properties (Access = private)
        app   % SymphonyApp instance
    end

    methods

        function obj = ModuleAcquisitionAdapter(app)
            obj.app = app;
        end

        function setProtocolPropertyMap(obj, map)
            if isempty(obj.app) || ~isvalid(obj.app)
                return;
            end
            obj.app.applyProtocolPropertyMap(map);
        end

    end

end