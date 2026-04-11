classdef PreviewView < handle
    %PREVIEWVIEW  Separate window for protocol stimulus preview.
    %   Displays a plot of the stimulus waveform that the current protocol
    %   will generate.  Opened from Preview → Show Preview Window.
    %   Call updateFromProtocol(protocol) whenever the protocol or its
    %   properties change to refresh the plot.

    properties (Access = private)
        fig matlab.ui.Figure
        ax matlab.ui.control.UIAxes
        parentFigure
    end

    methods
        function obj = PreviewView(parentFigure)
            if nargin < 1
                parentFigure = [];
            end
            obj.parentFigure = parentFigure;
            obj.buildUi();
        end

        function show(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                obj.fig.Visible = 'on';
                figure(obj.fig);  % bring to front
            end
        end

        function close(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                obj.fig.Visible = 'off';
            end
        end

        function tf = isReady(obj)
            tf = isvalid(obj) && ...
                 ~isempty(obj.fig) && isvalid(obj.fig);
        end

        function tf = isVisible(obj)
            tf = obj.isReady() && strcmp(obj.fig.Visible, 'on');
        end

        function delete(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                delete(obj.fig);
            end
        end

        function updateFromProtocol(obj, protocol)
            %UPDATEFROMPROTOCOL  Refresh the preview from a Protocol's getPreview.
            %   Calls the protocol's stimulus creation function via getPreview
            %   and plots the resulting waveforms on the preview axes.
            if ~obj.isReady()
                return;
            end

            cla(obj.ax);

            if isempty(protocol)
                title(obj.ax, 'No protocol selected');
                ylabel(obj.ax, '');
                return;
            end

            try
                % Protocol.getPreview expects a panel argument. We create a
                % temporary invisible figure with a panel, call getPreview to
                % get the StimuliPreview, extract its createStimuliFcn, then
                % invoke it ourselves and plot on our uiaxes.
                %
                % First try to get the stimuli function directly from the
                % preview object.
                tmpFig = figure('Visible', 'off');
                tmpPanel = uipanel(tmpFig);
                cleanupFig = onCleanup(@()delete(tmpFig));

                preview = protocol.getPreview(tmpPanel);

                if isempty(preview)
                    title(obj.ax, 'No preview available');
                    ylabel(obj.ax, '');
                    return;
                end

                % Get the stimulus creation function
                stimuli = preview.createStimuliFcn();
                if ~iscell(stimuli)
                    stimuli = {stimuli};
                end

                ylabels = {};
                hold(obj.ax, 'on');
                for i = 1:numel(stimuli)
                    stim = stimuli{i};
                    [quantities, units] = stim.getData();
                    sr = stim.sampleRate.quantityInBaseUnits;
                    x = (1:numel(quantities)) / sr;
                    plot(obj.ax, x, quantities);
                    ylabels{end+1} = units; %#ok<AGROW>
                end
                hold(obj.ax, 'off');

                xlabel(obj.ax, 'Time (s)');
                ylabel(obj.ax, strjoin(unique(ylabels), ', '));
                title(obj.ax, '');
            catch ex
                cla(obj.ax);
                title(obj.ax, 'Cannot create preview');
                ylabel(obj.ax, '');
                fprintf(2, 'PreviewView: %s\n', ex.message);
            end
        end

        function clearPreview(obj)
            if ~obj.isReady()
                return;
            end
            cla(obj.ax);
            title(obj.ax, '');
            xlabel(obj.ax, 'Time (s)');
            ylabel(obj.ax, '');
        end
    end

    methods (Access = private)
        function buildUi(obj)
            w = 500;
            h = 350;
            pos = obj.centerOnParent(w, h);

            obj.fig = uifigure( ...
                'Name', 'Preview', ...
                'Position', pos, ...
                'Visible', 'off', ...
                'CloseRequestFcn', @(~,~)obj.onClose());
            symphonyui.ui.ViewSettings.installAutoSave(obj.fig, 'PreviewView');

            layout = uigridlayout(obj.fig, [1 1]);
            layout.Padding = [8 8 8 8];

            obj.ax = uiaxes(layout);
            obj.ax.Layout.Row = 1;
            obj.ax.Layout.Column = 1;
            title(obj.ax, '');
            xlabel(obj.ax, 'Time (s)');
            ylabel(obj.ax, '');
        end

        function onClose(obj)
            % Hide instead of deleting so the window can be reopened
            obj.fig.Visible = 'off';
        end

        function pos = centerOnParent(obj, w, h)
            if ~isempty(obj.parentFigure) && isvalid(obj.parentFigure)
                pp = obj.parentFigure.Position;
                pos = [pp(1) + pp(3) + 10, pp(2) + (pp(4) - h) / 2, w, h];
            else
                pos = [500 200 w h];
            end
        end
    end
end
