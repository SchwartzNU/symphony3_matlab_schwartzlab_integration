classdef ViewSettings < appbox.Settings
    %VIEWSETTINGS  Persists view/figure position and size across sessions.
    %   Uses MATLAB's preference system via appbox.Settings.
    %
    %   Usage:
    %       s = symphonyui.ui.ViewSettings('MyDialog');
    %       % Restore position
    %       if ~isempty(s.position)
    %           fig.Position = s.position;
    %       end
    %       % Save on close
    %       s.position = fig.Position;
    %       s.save();

    properties
        position
    end

    methods
        function obj = ViewSettings(settingsKey)
            obj@appbox.Settings(settingsKey, 'symphonyui');
        end

        function p = get.position(obj)
            p = obj.get('position');
        end

        function set.position(obj, p)
            validateattributes(p, {'double'}, {'vector'});
            obj.put('position', p);
        end
    end

    methods (Static)
        function restorePosition(fig, settingsKey)
            %RESTOREPOSITION  Restore a figure's position from saved settings.
            try
                s = symphonyui.ui.ViewSettings(settingsKey);
                if ~isempty(s.position)
                    fig.Position = s.position;
                end
            catch
            end
        end

        function savePosition(fig, settingsKey)
            %SAVEPOSITION  Save a figure's position to settings.
            try
                s = symphonyui.ui.ViewSettings(settingsKey);
                s.position = fig.Position;
                s.save();
            catch
            end
        end

        function installAutoSave(fig, settingsKey)
            %INSTALLAUTOSAVE  Restore position now, and auto-save on close.
            %   Call this once after creating the figure.
            symphonyui.ui.ViewSettings.restorePosition(fig, settingsKey);
            oldCloseFcn = fig.CloseRequestFcn;
            fig.CloseRequestFcn = @(src, evt) onClose(src, evt, settingsKey, oldCloseFcn);

            function onClose(src, evt, key, prevFcn)
                try
                    symphonyui.ui.ViewSettings.savePosition(src, key);
                catch
                end
                if isa(prevFcn, 'function_handle')
                    prevFcn(src, evt);
                else
                    delete(src);
                end
            end
        end
    end
end
