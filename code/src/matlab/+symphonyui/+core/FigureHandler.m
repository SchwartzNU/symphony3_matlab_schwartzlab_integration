classdef FigureHandler < handle
    % A FigureHandler manages a figure displayed by a protocol. It creates the figure controls (typically a plot) and
    % updates the figure as each epoch completes. A FigureHandler is generally used to graphically present data and
    % perform online analysis.
    %
    % To write a new handler:
    %   1. Subclass FigureHandler
    %   2. Implement a constructor method to build the figure ui
    %   3. Implement the handleEpoch method to update the figure when epochs complete

    events (NotifyAccess = private)
        Closed  % Triggers when the handler is closed
    end

    properties (Access = protected)
        figureHandle    % uifigure handle
        log
        settings
    end

    properties
        % When true (default), this figure handler only receives data from
        % completed epochs — not partial streaming updates. Set to false
        % in subclass constructors for handlers that can display partial
        % data (e.g. ResponseFigure).
        requiresFullEpoch logical = true
    end

    methods

        function obj = FigureHandler(settingsKey)
            if nargin < 1
                settingsKey = '';
            end

            % Use traditional figure (Java-backed) for maximum rendering
            % performance.  The main SymphonyApp UI uses uifigure, but
            % figure handlers are independent plotting windows where speed
            % matters more than web-component support.
            obj.figureHandle = figure( ...
                'Name', '', ...
                'NumberTitle', 'off', ...
                'MenuBar', 'none', ...
                'Toolbar', 'figure', ...
                'HandleVisibility', 'off', ...
                'Visible', 'off', ...
                'CloseRequestFcn', @obj.onSelectedClose);

            obj.log = log4m.LogManager.getLogger(class(obj));
            obj.settings = symphonyui.core.FigureHandlerSettings([matlab.lang.makeValidName(class(obj)) '_' settingsKey]);
            try
                obj.loadSettings();
            catch x
                obj.log.debug(['Failed to load figure handler settings: ' x.message], x);
            end
        end

        function delete(obj)
            obj.close();
        end

        function handleEpochOrInterval(obj, epochOrInterval)
            if ~epochOrInterval.isInterval()
                obj.handleEpoch(epochOrInterval);
            end
        end

        function handleEpoch(obj, epoch) %#ok<INUSD>

        end

        function show(obj)
            obj.figureHandle.Visible = 'on';
            figure(obj.figureHandle);
            drawnow limitrate;
        end

        function clear(obj) %#ok<MANU>

        end

        function hide(obj)
            obj.figureHandle.Visible = 'off';
        end

        function close(obj)
            if ~isvalid(obj.figureHandle)
                return;
            end
            try
                obj.saveSettings();
            catch x
                obj.log.debug(['Failed to save figure handler settings: ' x.message], x);
            end
            delete(obj.figureHandle);
            notify(obj, 'Closed');
        end

        function loadSettings(obj)
            if ~isempty(obj.settings.figurePosition)
                obj.figureHandle.Position = obj.settings.figurePosition;
            end
        end

        function saveSettings(obj)
            obj.settings.figurePosition = obj.figureHandle.Position;
            obj.settings.save();
        end

    end

    methods (Access = protected)

        function onSelectedClose(obj, ~, ~)
            obj.close();
        end

        function ax = createAxes(obj, varargin)
            % Create axes inside the figure.
            ax = axes(obj.figureHandle, varargin{:});
        end

        function tf = isStreamingActive(obj, epoch, device) %#ok<INUSL>
            % Returns true if the response for the given device is in
            % streaming (ring buffer) mode. Use this in handleEpoch to
            % adapt rendering for partial data windows.
            tf = false;
            if epoch.hasResponse(device)
                response = epoch.getResponse(device);
                tf = response.isStreaming();
            end
        end

    end

end
