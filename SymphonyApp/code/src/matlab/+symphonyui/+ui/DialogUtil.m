classdef DialogUtil
    %DIALOGUTIL  Shared utilities for UIFigure-based dialogs.

    methods (Static)
        function setKeyPressFcnRecursive(parent, fcn)
            %SETKEYPRESSFCNRECURSIVE  Set KeyPressFcn on all interactive children.
            %   UIFigure doesn't propagate KeyPressFcn from child controls
            %   to the figure. This helper sets the same callback on every
            %   control that supports KeyPressFcn (dropdowns, editfields,
            %   checkboxes, listboxes, etc.) so Enter/Escape work regardless
            %   of which control has focus.
            %
            %   IMPORTANT: For uieditfield controls, the wrapper first moves
            %   focus away from the field before calling the handler. This
            %   forces the field to commit its typed text to .Value. Without
            %   this, KeyPressFcn fires BEFORE the value is committed, so
            %   reading .Value in the handler returns the stale (old) value.
            try
                ch = parent.Children;
            catch
                return;
            end
            for i = 1:numel(ch)
                if isprop(ch(i), 'KeyPressFcn')
                    try
                        if isa(ch(i), 'matlab.ui.control.EditField') || ...
                           isa(ch(i), 'matlab.ui.control.NumericEditField')
                            % Wrap: blur the field to commit text, then call handler
                            ch(i).KeyPressFcn = @(s,e) symphonyui.ui.DialogUtil.commitThenDispatch(s, e, fcn);
                        else
                            ch(i).KeyPressFcn = fcn;
                        end
                    catch
                    end
                end
                if isprop(ch(i), 'Children')
                    symphonyui.ui.DialogUtil.setKeyPressFcnRecursive(ch(i), fcn);
                end
            end
        end

        function commitThenDispatch(src, event, fcn)
            %COMMITTHENDISPATCH  Force edit field to commit, then call handler.
            %   Moving focus away from a uieditfield causes it to commit the
            %   currently typed text into .Value. We move focus to the parent
            %   figure, process one drawnow so .Value updates, then dispatch.
            if strcmp(event.Key, 'return') || strcmp(event.Key, 'escape')
                try
                    fig = ancestor(src, 'figure');
                    if ~isempty(fig)
                        focus(fig);
                        drawnow limitrate;
                    end
                catch
                end
            end
            fcn(src, event);
        end
    end
end
