classdef FigureHandlerManager < handle
    % A FigureHandlerManager manages figure handlers for a protocol.
    %
    % Schwartz Lab additions: figure plotting must never be able to break
    % acquisition.
    %   - Every handler is updated inside its own try/catch. A handler that
    %     errors is reported once, closed, and (in 'all' mode) replaced by a
    %     raw symphonyui.builtin.figures.ResponseFigure for its device(s), so
    %     the remaining figures keep updating and the user still sees data.
    %   - A handler whose constructor errors in showFigure is replaced the
    %     same way instead of aborting the protocol's prepareRun.
    %   - symphonyui.app.Options.figureHandlerMode selects 'all' (default),
    %     'rawTrace' (only ResponseFigures for the devices a protocol would
    %     have plotted) or 'none' (no figures). It is read on every
    %     showFigure call, i.e. at the start of each run.

    properties (Access = private)
        log
    end

    properties (Access = private, Transient)
        figureHandlers
    end

    methods

        function obj = FigureHandlerManager()
            obj.log = log4m.LogManager.getLogger(class(obj));
        end

        function delete(obj)
            obj.closeFigures();
        end

        function h = showFigure(obj, className, varargin)
            mode = symphonyui.core.FigureHandlerManager.getMode();
            switch mode
                case 'none'
                    h = [];
                    return;
                case 'rawTrace'
                    h = obj.showRawTraceFigures(symphonyui.core.FigureHandlerManager.findDevices(varargin));
                    return;
            end

            try
                h = obj.showHandler(className, varargin{:});
            catch ex
                obj.reportFailure(className, ex, 'could not be created');
                h = obj.showRawTraceFigures(symphonyui.core.FigureHandlerManager.findDevices(varargin));
            end
        end

        function updateFigures(obj, epochOrInterval)
            handlers = obj.figureHandlers;   % snapshot: a failure edits the list
            for i = 1:numel(handlers)
                handler = handlers{i};
                if ~isvalid(handler)
                    continue;
                end
                try
                    handler.handleEpochOrInterval(epochOrInterval);
                catch ex
                    obj.onHandlerFailed(handler, ex);
                end
            end
        end

        function updateStreamingFigures(obj, epoch)
            % Update only figure handlers that can display partial/streaming
            % data (requiresFullEpoch = false). Handlers that need the full
            % epoch (MeanResponse, ResponseStatistics, Progress, etc.) are
            % skipped here and updated normally on CompletedEpoch.
            handlers = obj.figureHandlers;
            for i = 1:numel(handlers)
                handler = handlers{i};
                try
                    if isvalid(handler) && ~handler.requiresFullEpoch
                        handler.handleEpoch(epoch);
                    end
                catch
                    % Silently skip handlers that can't handle partial data
                end
            end
        end

        function clearFigures(obj)
            handlers = obj.figureHandlers;
            for i = 1:numel(handlers)
                try
                    if isvalid(handlers{i})
                        handlers{i}.clear();
                    end
                catch ex
                    obj.onHandlerFailed(handlers{i}, ex);
                end
            end
        end

        function closeFigures(obj)
            while ~isempty(obj.figureHandlers)
                handler = obj.figureHandlers{1};
                try
                    handler.close();
                catch ex
                    obj.log.warn(sprintf('%s failed to close: %s', class(handler), ex.message));
                end
                % close() normally removes the handler via the Closed event;
                % make sure a misbehaving handler cannot keep us in the loop.
                obj.figureHandlers(cellfun(@(h) h == handler, obj.figureHandlers)) = [];
                if isvalid(handler)
                    delete(handler);
                end
            end
        end

        function h = getFigureHandlers(obj)
            h = obj.figureHandlers;
        end

    end

    methods (Access = private)

        function h = showHandler(obj, className, varargin)
            % Original behaviour: one handler per class, reused across runs.
            for i = 1:numel(obj.figureHandlers)
                handler = obj.figureHandlers{i};
                if strcmp(class(handler), className)
                    % Reset the handler with new args if it supports reset
                    if ismethod(handler, 'reset') && ~isempty(varargin)
                        try
                            handler.reset(varargin{:});
                        catch
                        end
                    end
                    handler.show();
                    h = handler;
                    return;
                end
            end

            constructor = str2func(className);
            handler = constructor(varargin{:});
            handler.show();
            obj.figureHandlers{end + 1} = handler;
            addlistener(handler, 'Closed', @obj.onFigureHandlerClosed);
            h = handler;
        end

        function h = showRawTraceFigures(obj, devices)
            % One ResponseFigure per device (reused if already open).
            h = [];
            for i = 1:numel(devices)
                device = devices{i};
                existing = obj.findRawTraceFigure(device);
                try
                    if isempty(existing)
                        handler = symphonyui.builtin.figures.ResponseFigure(device);
                        handler.show();
                        obj.figureHandlers{end + 1} = handler;
                        addlistener(handler, 'Closed', @obj.onFigureHandlerClosed);
                    else
                        existing.show();
                        handler = existing;
                    end
                    h = handler;
                catch ex
                    obj.reportFailure('symphonyui.builtin.figures.ResponseFigure', ex, 'could not be created');
                end
            end
        end

        function handler = findRawTraceFigure(obj, device)
            handler = [];
            for i = 1:numel(obj.figureHandlers)
                hd = obj.figureHandlers{i};
                if isa(hd, 'symphonyui.builtin.figures.ResponseFigure') && isvalid(hd) ...
                        && isequal(hd.device, device)
                    handler = hd;
                    return;
                end
            end
        end

        function onHandlerFailed(obj, handler, ex)
            % Report once, close the handler, and fall back to a raw trace of
            % the device(s) it was plotting (unless it already was one).
            className = class(handler);
            obj.reportFailure(className, ex, 'has been closed');
            devices = {};
            if ~isa(handler, 'symphonyui.builtin.figures.ResponseFigure')
                devices = symphonyui.core.FigureHandlerManager.findDevicesOnHandler(handler);
            end
            try
                handler.close();
            catch
            end
            obj.figureHandlers(cellfun(@(h) h == handler, obj.figureHandlers)) = [];
            if isvalid(handler)
                delete(handler);
            end
            if strcmp(symphonyui.core.FigureHandlerManager.getMode(), 'all') && ~isempty(devices)
                obj.showRawTraceFigures(devices);
            end
        end

        function reportFailure(obj, className, ex, what)
            msg = sprintf('Figure handler %s %s: %s (acquisition continues)', className, what, ex.message);
            fprintf(2, '%s\n', msg);
            try
                obj.log.error(sprintf('%s\n%s', msg, ex.getReport('extended', 'hyperlinks', 'off')));
            catch
            end
        end

        function onFigureHandlerClosed(obj, handler, ~)
            index = cellfun(@(h)h == handler, obj.figureHandlers);
            delete(handler);
            obj.figureHandlers(index) = [];
        end

    end

    methods (Static)

        function mode = getMode()
            mode = 'all';
            try
                mode = symphonyui.app.Options.getDefault().figureHandlerMode;
            catch
            end
        end

        function devices = findDevices(args)
            % Unique symphonyui.core.Device objects found anywhere in a cell
            % array of constructor arguments (nested cells are searched).
            devices = {};
            for i = 1:numel(args)
                a = args{i};
                if iscell(a)
                    sub = symphonyui.core.FigureHandlerManager.findDevices(a);
                    devices = [devices, sub]; %#ok<AGROW>
                elseif isa(a, 'symphonyui.core.Device')
                    for k = 1:numel(a)
                        devices{end + 1} = a(k); %#ok<AGROW>
                    end
                end
            end
            keep = true(1, numel(devices));
            for i = 2:numel(devices)
                for j = 1:i-1
                    if keep(j) && isequal(devices{i}, devices{j})
                        keep(i) = false;
                        break;
                    end
                end
            end
            devices = devices(keep);
        end

        function devices = findDevicesOnHandler(handler)
            % Devices exposed by a handler through public 'device'/'devices'
            % properties (ResponseFigure, the lab's ResponseAnalysisFigure, ...).
            devices = {};
            names = {'device', 'devices'};
            for n = 1:numel(names)
                try
                    if isprop(handler, names{n})
                        v = handler.(names{n});
                        devices = [devices, symphonyui.core.FigureHandlerManager.findDevices({v})]; %#ok<AGROW>
                    end
                catch
                end
            end
        end

    end

end
