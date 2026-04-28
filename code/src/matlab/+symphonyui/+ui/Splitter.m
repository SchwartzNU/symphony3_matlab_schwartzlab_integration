classdef Splitter < handle
    %SPLITTER  A draggable divider bar for resizing two adjacent panels in a uifigure.
    %   Provides horizontal (left/right) or vertical (top/bottom) splitting.
    %
    %   Usage:
    %       sp = symphonyui.ui.Splitter(parent, 'horizontal', 0.35);
    %       sp.LeftOrTop   — container for left (or top) content
    %       sp.RightOrBottom — container for right (or bottom) content
    %
    %   The parent must be a uifigure or uipanel with AutoResizeChildren='off'.

    properties (SetAccess = private)
        LeftOrTop matlab.ui.container.Panel
        RightOrBottom matlab.ui.container.Panel
    end

    properties (Access = private)
        parent
        direction  % 'horizontal' or 'vertical'
        fraction   % 0..1, fraction allocated to LeftOrTop
        barWidth = 5
        bar matlab.ui.container.Panel
        dragging = false
        dragOffset = 0
        minFraction = 0.1
        maxFraction = 0.9
    end

    methods
        function obj = Splitter(parent, direction, initialFraction)
            if nargin < 2, direction = 'horizontal'; end
            if nargin < 3, initialFraction = 0.35; end

            obj.parent = parent;
            obj.direction = direction;
            obj.fraction = initialFraction;

            % Ensure parent doesn't auto-resize children
            if isprop(parent, 'AutoResizeChildren')
                parent.AutoResizeChildren = 'off';
            end

            obj.LeftOrTop = uipanel(parent, 'BorderType', 'none', 'Units', 'pixels');
            obj.bar = uipanel(parent, 'BorderType', 'none', 'Units', 'pixels', ...
                'BackgroundColor', [0.78 0.78 0.78]);
            obj.RightOrBottom = uipanel(parent, 'BorderType', 'none', 'Units', 'pixels');

            % Drag events on the bar
            obj.bar.ButtonDownFcn = @(~, e) obj.onBarMouseDown(e);

            % Resize callback on parent
            parent.SizeChangedFcn = @(~,~) obj.doLayout();

            obj.doLayout();
        end

        function setFraction(obj, f)
            obj.fraction = max(obj.minFraction, min(obj.maxFraction, f));
            obj.doLayout();
        end
    end

    methods (Access = private)
        function doLayout(obj)
            pos = obj.getParentInnerPos();
            if isempty(pos) || pos(3) < 20 || pos(4) < 20
                return;
            end
            % Use only width/height from InnerPosition; children are
            % positioned relative to (0,0) inside the parent panel.
            w = pos(3); h = pos(4);
            bw = obj.barWidth;

            if strcmp(obj.direction, 'horizontal')
                leftW = round((w - bw) * obj.fraction);
                rightW = w - leftW - bw;
                obj.LeftOrTop.Position = [0, 0, max(leftW, 1), h];
                obj.bar.Position = [leftW, 0, bw, h];
                obj.RightOrBottom.Position = [leftW + bw, 0, max(rightW, 1), h];
            else
                botH = round((h - bw) * (1 - obj.fraction));
                topH = h - botH - bw;
                obj.RightOrBottom.Position = [0, 0, w, max(botH, 1)];
                obj.bar.Position = [0, botH, w, bw];
                obj.LeftOrTop.Position = [0, botH + bw, w, max(topH, 1)];
            end

            % SizeChangedFcn doesn't fire on programmatic Position changes.
            % Fire each panel's own SizeChangedFcn so nested splitters and
            % content (e.g. cardStack) resize correctly.
            symphonyui.ui.Splitter.fireSizeChanged(obj.LeftOrTop);
            symphonyui.ui.Splitter.fireSizeChanged(obj.RightOrBottom);
        end

        function onBarMouseDown(obj, ~)
            f = ancestor(obj.parent, 'figure');
            if isempty(f), return; end

            obj.dragging = true;

            % Set cursor
            if strcmp(obj.direction, 'horizontal')
                f.Pointer = 'left';
            else
                f.Pointer = 'top';
            end

            % Use figure-level motion/up
            f.WindowButtonMotionFcn = @(~,~) obj.onMouseMove(f);
            f.WindowButtonUpFcn = @(~,~) obj.onMouseUp(f);
        end

        function onMouseMove(obj, fig)
            if ~obj.dragging, return; end

            cp = fig.CurrentPoint;  % [x, y] in figure pixels
            pos = obj.getParentInnerPos();
            figPos = obj.getParentFigureOffset();

            if strcmp(obj.direction, 'horizontal')
                relX = cp(1) - figPos(1) - pos(1);
                totalW = pos(3) - obj.barWidth;
                newFrac = relX / max(totalW, 1);
            else
                relY = cp(2) - figPos(2) - pos(2);
                totalH = pos(4) - obj.barWidth;
                newFrac = 1 - (relY / max(totalH, 1));
            end

            obj.fraction = max(obj.minFraction, min(obj.maxFraction, newFrac));
            obj.doLayout();
        end

        function onMouseUp(obj, fig)
            obj.dragging = false;
            fig.Pointer = 'arrow';
            fig.WindowButtonMotionFcn = '';
            fig.WindowButtonUpFcn = '';
        end

        function pos = getParentInnerPos(obj)
            try
                if isprop(obj.parent, 'InnerPosition')
                    pos = obj.parent.InnerPosition;
                else
                    pos = obj.parent.Position;
                end
            catch
                pos = [0 0 100 100];
            end
        end

        function offset = getParentFigureOffset(obj)
            % Compute the pixel offset of the parent's origin relative to the figure.
            offset = [0 0];
            p = obj.parent;
            while ~isempty(p) && ~isa(p, 'matlab.ui.Figure')
                try
                    ppos = p.Position;
                    offset = offset + ppos(1:2);
                catch
                    break;
                end
                p = p.Parent;
            end
        end
    end

    methods (Static, Access = private)
        function fireSizeChanged(panel)
            % Fire SizeChangedFcn on a panel. This is needed because MATLAB
            % doesn't fire SizeChangedFcn when Position is set programmatically.
            hasCb = false;
            try
                if isprop(panel, 'SizeChangedFcn') && ~isempty(panel.SizeChangedFcn)
                    cb = panel.SizeChangedFcn;
                    if isa(cb, 'function_handle')
                        cb(panel, []);
                        hasCb = true;
                    end
                end
            catch
            end
            % If the panel has no SizeChangedFcn (i.e. no Splitter or
            % custom layout manages it), resize its single child to fill.
            if ~hasCb
                try
                    ip = panel.InnerPosition;
                    pw = max(1, ip(3));
                    ph = max(1, ip(4));
                    ch = panel.Children;
                    for k = 1:numel(ch)
                        try
                            ch(k).Units = 'pixels';
                            ch(k).Position = [0 0 pw ph];
                        catch
                            % uigridlayout doesn't support Units/Position
                        end
                    end
                catch
                end
            end
        end
    end
end
