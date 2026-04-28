classdef Module < handle
    %MODULE  Base class for Symphony modules (UIFigure-based).
    %   Modules are auxiliary windows that provide extra functionality such as
    %   background control, device configuration, etc. Each module gets its own
    %   UIFigure window and is given references to the app services.
    %
    %   Subclasses should override:
    %       createUi(figureHandle)  - Build the module's UI inside the figure
    %       willGo()                - Called after services are set, before showing
    %       bind()                  - Called after willGo() to set up listeners
    %
    %   Services available to subclasses:
    %       obj.documentationService
    %       obj.acquisitionService
    %       obj.configurationService

    events
        Stopped  % Fired when the module window is closed
    end

    properties (SetAccess = private)
        documentationService
        acquisitionService
        configurationService
    end

    properties (Access = private)
        figureHandle  % matlab.ui.Figure
        listeners_    % cell array of listener handles
        isPreloaded logical = false
    end

    methods

        function obj = Module()
            obj.listeners_ = {};
            obj.figureHandle = uifigure( ...
                'Visible', 'off', ...
                'CloseRequestFcn', @(~,~)obj.stop());
            try
                obj.createUi(obj.figureHandle);
            catch x
                delete(obj.figureHandle);
                rethrow(x);
            end
        end

        function delete(obj)
            obj.removeAllListeners();
            if ~isempty(obj.figureHandle) && isvalid(obj.figureHandle)
                delete(obj.figureHandle);
            end
        end

        function createUi(obj, figureHandle) %#ok<INUSD>
            % Override in subclass to build module UI
        end

        function setDocumentationService(obj, service)
            obj.documentationService = service;
            obj.didSetDocumentationService();
        end

        function didSetDocumentationService(obj) %#ok<MANU>
        end

        function setAcquisitionService(obj, service)
            obj.acquisitionService = service;
            obj.didSetAcquisitionService();
        end

        function didSetAcquisitionService(obj) %#ok<MANU>
        end

        function setConfigurationService(obj, service)
            obj.configurationService = service;
            obj.didSetConfigurationService();
        end

        function didSetConfigurationService(obj) %#ok<MANU>
        end

        function preload(obj)
            %PRELOAD  Initialize the module without showing it.
            %   Runs willGo() and bind() but keeps the figure hidden.
            %   A subsequent call to go() or show() makes it visible instantly.
            if obj.isPreloaded
                return;
            end
            try
                obj.willGo();
            catch x
                fprintf(2, 'Module willGo error: %s\n', x.message);
            end
            try
                obj.bind();
            catch x
                fprintf(2, 'Module bind error: %s\n', x.message);
            end
            obj.isPreloaded = true;
        end

        function go(obj)
            %GO  Initialize and show the module.
            obj.preload();  % no-op if already preloaded
            obj.figureHandle.Visible = 'on';
        end

        function show(obj)
            %SHOW  Bring the module window to the front.
            if ~isempty(obj.figureHandle) && isvalid(obj.figureHandle)
                obj.figureHandle.Visible = 'on';
                figure(obj.figureHandle);
            end
        end

        function stop(obj)
            %STOP  Close the module and fire the Stopped event.
            if ~isempty(obj.figureHandle) && isvalid(obj.figureHandle)
                delete(obj.figureHandle);
            end
            notify(obj, 'Stopped');
        end

        function h = getFigureHandle(obj)
            h = obj.figureHandle;
        end

    end

    methods (Access = protected)

        function willGo(obj) %#ok<MANU>
            % Override in subclass for initialization after services are set
        end

        function bind(obj) %#ok<MANU>
            % Override in subclass to set up event listeners
        end

        function l = addListener(obj, varargin)
            %ADDLISTENER  Add a listener and track it for cleanup.
            l = addlistener(varargin{:});
            obj.listeners_{end+1} = l;
        end

        function removeListener(obj, l)
            idx = cellfun(@(x)x == l, obj.listeners_);
            delete(l);
            obj.listeners_(idx) = [];
        end

    end

    methods (Access = private)

        function removeAllListeners(obj)
            for i = 1:numel(obj.listeners_)
                try delete(obj.listeners_{i}); catch, end
            end
            obj.listeners_ = {};
        end

    end

end
