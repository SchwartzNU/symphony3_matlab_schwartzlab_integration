classdef ModuleAcquisitionAdapter < handle
    %MODULEACQUISITIONADAPTER  Acquisition service handed to modules.
    %   Symphony 2 gave modules a symphonyui.app.AcquisitionService. In the
    %   UIFigure app the protocol, controller and UI live on SymphonyApp, so this
    %   adapter forwards the AcquisitionService calls that extension modules use
    %   to the live app:
    %
    %     setProtocolPropertyMap           sa_labs.modules.CommonControl
    %     selectProtocol                   sa_labs.modules.ReceptiveFieldMapper
    %     setProtocolProperty              ReceptiveFieldMapper
    %     getProtocolPropertyDescriptors   ReceptiveFieldMapper
    %     setProtocolFigureHandlerManager  ReceptiveFieldMapper (Schwartz Lab
    %                                      Symphony 2 modification)
    %     record / viewOnly / stop         ReceptiveFieldMapper
    %     getControllerState               ReceptiveFieldMapper
    %
    %   Each call drives the same code path the UI buttons use, so the property
    %   grid, acquire buttons and preview stay in sync.

    events (NotifyAccess = private)
        SelectedProtocol
        SetProtocolProperties
        SetProtocolFigureHandlerManager
        ChangedControllerState
    end

    properties (Access = private)
        app   % SymphonyApp instance
    end

    methods

        function obj = ModuleAcquisitionAdapter(app)
            obj.app = app;
        end

        function selectProtocol(obj, protocolId)
            obj.requireApp();
            obj.app.selectProtocolById(protocolId);
            notify(obj, 'SelectedProtocol');
        end

        function id = getSelectedProtocol(obj)
            obj.requireApp();
            p = obj.app.getCurrentProtocol();
            if isempty(p)
                id = '';
            else
                id = class(p);
            end
        end

        function p = getCurrentProtocol(obj)
            obj.requireApp();
            p = obj.app.getCurrentProtocol();
        end

        function setProtocolProperty(obj, name, value)
            obj.requireApp();
            m = containers.Map();
            m(name) = value;
            obj.app.applyProtocolPropertyMap(m);
            notify(obj, 'SetProtocolProperties');
        end

        function setProtocolPropertyMap(obj, map)
            obj.requireApp();
            obj.app.applyProtocolPropertyMap(map);
            notify(obj, 'SetProtocolProperties');
        end

        function m = getProtocolPropertyMap(obj)
            p = obj.getCurrentProtocol();
            if isempty(p)
                m = containers.Map();
            else
                m = p.getPropertyMap();
            end
        end

        function d = getProtocolPropertyDescriptors(obj)
            p = obj.getCurrentProtocol();
            if isempty(p)
                d = symphonyui.core.PropertyDescriptor.empty(0, 1);
            else
                d = p.getPropertyDescriptors();
            end
        end

        function setProtocolFigureHandlerManager(obj, manager)
            p = obj.getCurrentProtocol();
            if isempty(p)
                error('No protocol is selected');
            end
            p.setFigureHandlerManager(manager);
            notify(obj, 'SetProtocolFigureHandlerManager');
        end

        function viewOnly(obj)
            obj.requireApp();
            obj.app.viewOnly();
            notify(obj, 'ChangedControllerState');
        end

        function record(obj)
            obj.requireApp();
            obj.app.record();
            notify(obj, 'ChangedControllerState');
        end

        function stop(obj)
            obj.requireApp();
            obj.app.stopAcquisition();
            notify(obj, 'ChangedControllerState');
        end

        function s = getControllerState(obj)
            obj.requireApp();
            s = obj.app.getControllerState();
        end

    end

    methods (Access = private)

        function requireApp(obj)
            if isempty(obj.app) || ~isvalid(obj.app)
                error('The Symphony app is no longer available');
            end
        end

    end

end
