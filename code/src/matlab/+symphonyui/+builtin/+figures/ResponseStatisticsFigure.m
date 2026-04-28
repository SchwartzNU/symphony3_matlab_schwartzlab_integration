classdef ResponseStatisticsFigure < symphonyui.core.FigureHandler
    % Plots statistics calculated from the response of a specified device for each epoch run.

    properties (SetAccess = private)
        device
        measurementCallbacks
        measurementRegion
        baselineRegion
    end

    properties (Access = private)
        axesHandles
        markers
    end

    methods

        function obj = ResponseStatisticsFigure(device, measurementCallbacks, varargin)
            if ~iscell(measurementCallbacks)
                measurementCallbacks = {measurementCallbacks};
            end

            ip = inputParser();
            ip.addParameter('measurementRegion', [], @(x)isnumeric(x) || isvector(x));
            ip.addParameter('baselineRegion', [], @(x)isnumeric(x) || isvector(x));
            ip.parse(varargin{:});

            obj.device = device;
            obj.measurementCallbacks = measurementCallbacks;
            obj.measurementRegion = ip.Results.measurementRegion;
            obj.baselineRegion = ip.Results.baselineRegion;

            obj.createUi();
        end

        function createUi(obj)
            nPlots = numel(obj.measurementCallbacks);

            obj.axesHandles = gobjects(1, nPlots);
            for i = 1:nPlots
                ax = subplot(nPlots, 1, i, 'Parent', obj.figureHandle);
                ylabel(ax, func2str(obj.measurementCallbacks{i}));
                if i < nPlots
                    set(ax, 'XTickLabel', []);
                end
                obj.axesHandles(i) = ax;
            end
            xlabel(obj.axesHandles(end), 'epoch');

            obj.setTitle([obj.device.name ' Response Statistics']);
        end

        function setTitle(obj, t)
            obj.figureHandle.Name = t;
            title(obj.axesHandles(1), t);
        end

        function handleEpoch(obj, epoch)
            if ~epoch.hasResponse(obj.device)
                return;  % Silently skip — don't crash acquisition
            end

            response = epoch.getResponse(obj.device);
            try
                quantities = response.getFullData();
            catch
                return;
            end
            if isempty(quantities) || numel(quantities) < 2
                return;
            end
            nPts = numel(quantities);
            rate = response.sampleRate.quantityInBaseUnits;

            if ~isempty(obj.baselineRegion)
                x1 = max(1, min(round(obj.baselineRegion(1) / 1e3 * rate), nPts));
                x2 = max(1, min(round(obj.baselineRegion(2) / 1e3 * rate), nPts));
                if x2 > x1 && x2 <= nPts
                    baseline = quantities(x1:x2);
                    quantities = quantities - mean(baseline);
                end
            end

            nPts = numel(quantities);
            if ~isempty(obj.measurementRegion)
                x1 = max(1, min(round(obj.measurementRegion(1) / 1e3 * rate), nPts));
                x2 = max(1, min(round(obj.measurementRegion(2) / 1e3 * rate), nPts));
                if x2 >= x1 && x2 <= nPts
                    quantities = quantities(x1:x2);
                end
            end

            for i = 1:numel(obj.measurementCallbacks)
                fcn = obj.measurementCallbacks{i};
                result = fcn(quantities);
                if numel(obj.markers) < i
                    colorOrder = get(groot, 'defaultAxesColorOrder');
                    color = colorOrder(mod(i - 1, size(colorOrder, 1)) + 1, :);
                    obj.markers(i) = line(1, result, 'Parent', obj.axesHandles(i), ...
                        'LineStyle', 'none', ...
                        'Marker', 'o', ...
                        'MarkerEdgeColor', color, ...
                        'MarkerFaceColor', color);
                else
                    x = get(obj.markers(i), 'XData');
                    y = get(obj.markers(i), 'YData');
                    set(obj.markers(i), 'XData', [x x(end)+1], 'YData', [y result]);
                end
            end
        end

    end

end
