classdef MeanResponseFigure < symphonyui.core.FigureHandler
    % Plots the mean response of a specified device for all epochs run.

    properties (SetAccess = private)
        device
        groupBy
        sweepColor
        storedSweepColor
    end

    properties (Access = private)
        axesHandle
        sweeps
        storeSweepsBtn
        clearSweepsBtn
        previewLine   % Temporary line for streaming preview
    end

    methods

        function obj = MeanResponseFigure(device, varargin)
            co = get(groot, 'defaultAxesColorOrder');

            ip = inputParser();
            ip.addParameter('groupBy', [], @(x)iscellstr(x));
            ip.addParameter('sweepColor', co(1,:), @(x)ischar(x) || isvector(x));
            ip.addParameter('storedSweepColor', 'r', @(x)ischar(x) || isvector(x));
            ip.parse(varargin{:});

            obj.device = device;
            obj.groupBy = ip.Results.groupBy;
            obj.sweepColor = ip.Results.sweepColor;
            obj.storedSweepColor = ip.Results.storedSweepColor;
            obj.requiresFullEpoch = false;  % Show live preview during streaming

            obj.createUi();

            stored = obj.storedSweeps();
            for i = 1:numel(stored)
                stored{i}.line = line(stored{i}.x, stored{i}.y, ...
                    'Parent', obj.axesHandle, ...
                    'Color', obj.storedSweepColor, ...
                    'HandleVisibility', 'off');
            end
            obj.storedSweeps(stored);
        end

        function createUi(obj)
            % Toolbar buttons via uicontrol (traditional figure)
            tbPanel = uipanel(obj.figureHandle, 'Units', 'pixels', ...
                'Position', [0 0 1 1], 'BorderType', 'none');
            obj.storeSweepsBtn = uicontrol(tbPanel, 'Style', 'pushbutton', ...
                'String', 'Store', 'Units', 'pixels', 'Position', [4 2 60 24], ...
                'Callback', @(~,~)obj.onSelectedStoreSweeps());
            obj.clearSweepsBtn = uicontrol(tbPanel, 'Style', 'pushbutton', ...
                'String', 'Clear', 'Units', 'pixels', 'Position', [68 2 60 24], ...
                'Callback', @(~,~)obj.onSelectedClearSweeps());

            obj.axesHandle = axes(obj.figureHandle, ...
                'Position', [0.08 0.15 0.88 0.78]);

            obj.figureHandle.SizeChangedFcn = @(~,~)obj.onResize(tbPanel);
            obj.onResize(tbPanel);
            obj.axesHandle.XTickMode = 'auto';
            xlabel(obj.axesHandle, 'Time (s)');
            obj.sweeps = {};

            obj.setTitle([obj.device.name ' Mean Response']);
        end

        function setTitle(obj, t)
            obj.figureHandle.Name = t;
            title(obj.axesHandle, t);
        end

        function clear(obj)
            cla(obj.axesHandle);
            obj.sweeps = {};
        end

        function handleEpoch(obj, epoch)
            if ~epoch.hasResponse(obj.device)
                return;
            end

            response = epoch.getResponse(obj.device);
            [quantities, units] = response.getData();
            if isempty(quantities)
                return;
            end

            rate = response.sampleRate.quantityInBaseUnits;

            % ----------------------------------------------------------
            % INCOMPLETE EPOCH: show preview only, don't update the mean.
            % This is called by updateStreamingFigures during acquisition.
            % Without this guard, each periodic update would add partial
            % data to the mean, corrupting the running average.
            % ----------------------------------------------------------
            if ~epoch.isComplete()
                try
                    streaming = logical(response.isStreaming());
                catch
                    streaming = false;
                end

                if streaming
                    % Streaming active: show sliding window at correct position
                    totalSamples = response.getTotalSampleCount();
                    startSample = totalSamples - numel(quantities) + 1;
                    x = (startSample:totalSamples) / rate;
                else
                    % Pre-streaming: show all data from the beginning
                    x = (1:numel(quantities)) / rate;
                end
                y = quantities;

                % Create or update the preview line
                if isempty(obj.previewLine) || ~isvalid(obj.previewLine)
                    obj.previewLine = line(x, y, ...
                        'Parent', obj.axesHandle, ...
                        'Color', [obj.sweepColor 0.4], ...
                        'LineStyle', '-', ...
                        'LineWidth', 1.5, ...
                        'HandleVisibility', 'off');
                else
                    set(obj.previewLine, 'XData', x, 'YData', y);
                end

                obj.setTitle([obj.device.name ' Mean Response [streaming...]']);
                drawnow limitrate;
                return;  % Don't update the mean with partial data
            end

            % ----------------------------------------------------------
            % COMPLETED EPOCH: remove the preview line and update the
            % running mean with the full epoch data.
            % ----------------------------------------------------------
            % Remove streaming preview line
            if ~isempty(obj.previewLine) && isvalid(obj.previewLine)
                delete(obj.previewLine);
                obj.previewLine = [];
            end

            % Use getFullData() to get ALL accumulated samples (not just
            % the ring buffer window). This is critical for epochs that
            % exceeded the streaming threshold.
            fullQuantities = response.getFullData();
            if ~isempty(fullQuantities)
                quantities = fullQuantities;
            end

            x = (1:numel(quantities)) / rate;
            y = quantities;

            p = epoch.parameters;
            if isempty(obj.groupBy) && isnumeric(obj.groupBy)
                parameters = p;
            else
                parameters = containers.Map();
                for i = 1:length(obj.groupBy)
                    key = obj.groupBy{i};
                    parameters(key) = p(key);
                end
            end

            if isempty(parameters)
                t = 'All epochs grouped together';
            else
                t = ['Grouped by ' strjoin(parameters.keys, ', ')];
            end
            obj.setTitle([obj.device.name ' Mean Response (' t ')']);

            sweepIndex = [];
            for i = 1:numel(obj.sweeps)
                if isequal(obj.sweeps{i}.parameters, parameters)
                    sweepIndex = i;
                    break;
                end
            end

            if isempty(sweepIndex)
                sweep.parameters = parameters;
                sweep.x = x;
                sweep.y = y;
                sweep.count = 1;
                sweep.line = line(sweep.x, sweep.y, 'Parent', obj.axesHandle, 'Color', obj.sweepColor);
                obj.sweeps{end + 1} = sweep;
            else
                sweep = obj.sweeps{sweepIndex};
                if numel(sweep.y) == numel(y)
                    % Same length — running average
                    sweep.y = (sweep.y * sweep.count + y) / (sweep.count + 1);
                    sweep.count = sweep.count + 1;
                else
                    % Length mismatch — truncate to shorter length and average
                    minLen = min(numel(sweep.y), numel(y));
                    if minLen > 0 && sweep.count > 0
                        sweep.y = (sweep.y(1:minLen) * sweep.count + y(1:minLen)) / (sweep.count + 1);
                        sweep.x = x(1:minLen);
                        sweep.count = sweep.count + 1;
                    else
                        sweep.x = x;
                        sweep.y = y;
                        sweep.count = 1;
                    end
                end
                set(sweep.line, 'XData', sweep.x, 'YData', sweep.y);
                obj.sweeps{sweepIndex} = sweep;
            end

            ylabel(obj.axesHandle, units, 'Interpreter', 'none');
            drawnow limitrate;
        end

    end

    methods (Access = private)

        function onResize(obj, tbPanel)
            pos = obj.figureHandle.Position;
            tbPanel.Position = [0 0 pos(3) 28];
        end

        function onSelectedStoreSweeps(obj, ~, ~)
            obj.storeSweeps();
        end

        function storeSweeps(obj)
            obj.clearSweeps();

            store = obj.sweeps;
            for i = 1:numel(obj.sweeps)
                store{i}.line = copyobj(obj.sweeps{i}.line, obj.axesHandle);
                set(store{i}.line, ...
                    'Color', obj.storedSweepColor, ...
                    'HandleVisibility', 'off');
            end
            obj.storedSweeps(store);
        end

        function onSelectedClearSweeps(obj, ~, ~)
            obj.clearSweeps();
        end

        function clearSweeps(obj)
            stored = obj.storedSweeps();
            for i = 1:numel(stored)
                delete(stored{i}.line);
            end

            obj.storedSweeps([]);
        end

    end

    methods (Static)

        function sweeps = storedSweeps(sweeps)
            % This method stores sweeps across figure handlers.

            persistent stored;
            if nargin > 0
                stored = sweeps;
            end
            sweeps = stored;
        end

    end

end
