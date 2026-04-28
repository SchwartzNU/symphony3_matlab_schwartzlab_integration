classdef ResponseFigure < symphonyui.core.FigureHandler
    % Plots the response of a specified device in the most recent epoch.

    properties (SetAccess = private)
        device
        sweepColor
        storedSweepColor
    end

    properties (Access = private)
        axesHandle
        sweep
        storeSweepBtn
        clearSweepBtn
    end

    methods

        function obj = ResponseFigure(device, varargin)
            co = get(groot, 'defaultAxesColorOrder');

            ip = inputParser();
            ip.addParameter('sweepColor', co(1,:), @(x)ischar(x) || isvector(x));
            ip.addParameter('storedSweepColor', 'r', @(x)ischar(x) || isvector(x));
            ip.parse(varargin{:});

            obj.device = device;
            obj.sweepColor = ip.Results.sweepColor;
            obj.storedSweepColor = ip.Results.storedSweepColor;
            obj.requiresFullEpoch = false;  % Can display partial/streaming data

            obj.createUi();

            stored = obj.storedSweep();
            if ~isempty(stored)
                stored.line = line(stored.x, stored.y, ...
                    'Parent', obj.axesHandle, ...
                    'Color', obj.storedSweepColor, ...
                    'HandleVisibility', 'off');
            end
            obj.storedSweep(stored);
        end

        function createUi(obj)
            % Toolbar buttons via uicontrol (traditional figure)
            tbPanel = uipanel(obj.figureHandle, 'Units', 'pixels', ...
                'Position', [0 0 1 1], 'BorderType', 'none');
            obj.storeSweepBtn = uicontrol(tbPanel, 'Style', 'pushbutton', ...
                'String', 'Store', 'Units', 'pixels', 'Position', [4 2 60 24], ...
                'Callback', @(~,~)obj.onSelectedStoreSweep());
            obj.clearSweepBtn = uicontrol(tbPanel, 'Style', 'pushbutton', ...
                'String', 'Clear', 'Units', 'pixels', 'Position', [68 2 60 24], ...
                'Callback', @(~,~)obj.onSelectedClearSweep());

            % Axes with room for the toolbar at the bottom
            obj.axesHandle = axes(obj.figureHandle, ...
                'Position', [0.08 0.15 0.88 0.78]);
            xlabel(obj.axesHandle, 'Time (s)');

            % Resize callback to keep toolbar at the bottom
            obj.figureHandle.SizeChangedFcn = @(~,~)obj.onResize(tbPanel);
            obj.onResize(tbPanel);

            obj.setTitle([obj.device.name ' Response']);
        end

        function setTitle(obj, t)
            obj.figureHandle.Name = t;
            title(obj.axesHandle, t);
        end

        function clear(obj)
            cla(obj.axesHandle);
            obj.sweep = [];
        end

        function handleEpoch(obj, epoch)
            if ~epoch.hasResponse(obj.device)
                fprintf(2, 'ResponseFigure: no response for %s\n', obj.device.name);
                return;
            end

            response = epoch.getResponse(obj.device);
            [quantities, units] = response.getData();
            if numel(quantities) > 0
                rate = response.sampleRate.quantityInBaseUnits;
                if response.isStreaming()
                    % In streaming mode, show the correct time window
                    totalSamples = response.getTotalSampleCount();
                    startSample = totalSamples - numel(quantities) + 1;
                    x = (startSample:totalSamples) / rate;
                else
                    x = (1:numel(quantities)) / rate;
                end
                y = quantities;
            else
                x = [];
                y = [];
            end
            hasValidLine = false;
            if isstruct(obj.sweep) && isfield(obj.sweep, 'line')
                try
                    hasValidLine = isvalid(obj.sweep.line);
                catch
                end
            end
            if hasValidLine
                obj.sweep.x = x;
                obj.sweep.y = y;
                set(obj.sweep.line, 'XData', obj.sweep.x, 'YData', obj.sweep.y);
            else
                obj.sweep = [];
                obj.sweep.x = x;
                obj.sweep.y = y;
                obj.sweep.line = line(obj.sweep.x, obj.sweep.y, 'Parent', obj.axesHandle, 'Color', obj.sweepColor);
            end
            ylabel(obj.axesHandle, units, 'Interpreter', 'none');

            % Indicate streaming mode in title
            if response.isStreaming()
                title(obj.axesHandle, '(streaming)', 'FontSize', 9, 'FontWeight', 'normal');
            else
                title(obj.axesHandle, '');
            end

            % Force a visual refresh
            drawnow limitrate;
        end

    end

    methods (Access = private)

        function onResize(obj, tbPanel)
            pos = obj.figureHandle.Position;
            w = pos(3); h = pos(4);
            tbH = 28;
            tbPanel.Position = [0 0 w tbH];
        end

        function onSelectedStoreSweep(obj, ~, ~)
            obj.storeSweep();
        end

        function storeSweep(obj)
            obj.clearSweep();

            store = obj.sweep;
            if ~isempty(store)
                store.line = copyobj(obj.sweep.line, obj.axesHandle);
                set(store.line, ...
                    'Color', obj.storedSweepColor, ...
                    'HandleVisibility', 'off');
            end
            obj.storedSweep(store);
        end

        function onSelectedClearSweep(obj, ~, ~)
            obj.clearSweep();
        end

        function clearSweep(obj)
            stored = obj.storedSweep();
            if ~isempty(stored)
                delete(stored.line);
            end

            obj.storedSweep([]);
        end

    end

    methods (Static)

        function sweep = storedSweep(sweep)
            % This method stores a sweep across figure handlers.

            persistent stored;
            if nargin > 0
                stored = sweep;
            end
            sweep = stored;
        end

    end

end
