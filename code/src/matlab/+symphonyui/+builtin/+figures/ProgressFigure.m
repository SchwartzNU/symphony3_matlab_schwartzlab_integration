classdef ProgressFigure < symphonyui.core.FigureHandler

    properties (SetAccess = private)
        totalNumEpochs
    end

    properties (Access = private)
        numEpochsCompleted
        intervalSeconds
        averageEpochDuration
        statusText
        progressBarBg
        progressBarFill
        timeText
    end

    methods

        function obj = ProgressFigure(totalNumEpochs, varargin)
            ip = inputParser();
            ip.addParameter('intervalSeconds', 0, @(x)isscalar(x));
            ip.parse(varargin{:});

            obj.totalNumEpochs = double(totalNumEpochs(1));  % ensure scalar
            obj.numEpochsCompleted = 0;
            obj.intervalSeconds = ip.Results.intervalSeconds;

            obj.createUi();

            obj.updateProgress();
        end

        function createUi(obj)
            % Only set the default position if no saved position was loaded.
            if isempty(obj.settings.figurePosition)
                obj.figureHandle.Position = [100 200 350 120];
            end
            obj.figureHandle.Resize = 'off';

            % Status text
            obj.statusText = uicontrol(obj.figureHandle, 'Style', 'text', ...
                'String', '', 'Units', 'normalized', ...
                'Position', [0.05 0.65 0.9 0.25], ...
                'HorizontalAlignment', 'left', 'FontSize', 10);

            % Progress bar background + fill
            obj.progressBarBg = uipanel(obj.figureHandle, 'Units', 'normalized', ...
                'Position', [0.05 0.4 0.9 0.2], ...
                'BackgroundColor', [0.9 0.9 0.9], 'BorderType', 'line');
            obj.progressBarFill = uipanel(obj.progressBarBg, 'Units', 'normalized', ...
                'Position', [0 0 0 1], ...
                'BackgroundColor', [0.3 0.6 1.0], 'BorderType', 'none');

            % Time text
            obj.timeText = uicontrol(obj.figureHandle, 'Style', 'text', ...
                'String', '', 'Units', 'normalized', ...
                'Position', [0.05 0.08 0.9 0.25], ...
                'HorizontalAlignment', 'left', 'FontSize', 10);

            obj.figureHandle.Name = 'Progress';
        end

        function handleEpoch(obj, epoch)
            obj.numEpochsCompleted = obj.numEpochsCompleted + 1;

            if isempty(obj.averageEpochDuration)
                obj.averageEpochDuration = epoch.duration;
            else
                obj.averageEpochDuration = obj.averageEpochDuration * (obj.numEpochsCompleted - 1)/obj.numEpochsCompleted + epoch.duration/obj.numEpochsCompleted;
            end

            obj.updateProgress();
        end

        function reset(obj, totalNumEpochs, varargin)
            % Reset the progress bar for a new run, optionally with a new total.
            if nargin >= 2 && ~isempty(totalNumEpochs)
                obj.totalNumEpochs = double(totalNumEpochs(1));
            end
            if nargin >= 3
                ip = inputParser();
                ip.addParameter('intervalSeconds', obj.intervalSeconds, @(x)isscalar(x));
                ip.parse(varargin{:});
                obj.intervalSeconds = ip.Results.intervalSeconds;
            end
            obj.numEpochsCompleted = 0;
            obj.averageEpochDuration = [];
            obj.updateProgress();
        end

        function clear(obj)
            obj.numEpochsCompleted = 0;
            obj.averageEpochDuration = [];

            obj.updateProgress();
        end

        function updateProgress(obj)
            obj.statusText.String = sprintf('%d of %d epochs have completed', ...
                obj.numEpochsCompleted, obj.totalNumEpochs);

            % Update progress bar fill width
            if obj.totalNumEpochs > 0
                frac = obj.numEpochsCompleted / obj.totalNumEpochs;
            else
                frac = 0;
            end
            obj.progressBarFill.Position = [0 0 max(frac, 0.001) 1];

            timeLeft = '';
            if ~isempty(obj.averageEpochDuration)
                n = obj.totalNumEpochs - obj.numEpochsCompleted;
                d = obj.averageEpochDuration * n + seconds(obj.intervalSeconds) * (n - 1);
                [h, m, s] = hms(d);
                if h >= 1
                    timeLeft = sprintf('%.0f hours, %.0f minutes', h, m);
                elseif minutes(d) >= 1
                    timeLeft = sprintf('%.0f minutes, %.0f seconds', m, s);
                else
                    timeLeft = sprintf('%.0f seconds', s);
                end
            end
            obj.timeText.String = ['Estimated time left: ' timeLeft];
        end

    end

end