classdef BackgroundControl < symphonyui.ui.Module

    properties (Access = private)
        devices
        deviceListeners
        deviceTable  % uitable for editing background values
    end

    methods

        function createUi(obj, figureHandle)
            figureHandle.Name = 'Background Control';
            figureHandle.Position(3:4) = [320 200];

            grid = uigridlayout(figureHandle, [1 1]);
            grid.Padding = [6 6 6 6];

            obj.deviceTable = uitable(grid, ...
                'ColumnName', {'Device', 'Background', 'Units'}, ...
                'ColumnEditable', [false true false], ...
                'ColumnWidth', {'1x', 80, 60}, ...
                'CellEditCallback', @(src, evt)obj.onCellEdit(src, evt));
        end

    end

    methods (Access = protected)

        function willGo(obj)
            obj.devices = obj.configurationService.getOutputDevices();
            obj.populateTable();
        end

        function bind(obj)
            bind@symphonyui.ui.Module(obj);
            obj.bindDevices();

            c = obj.configurationService;
            obj.addListener(c, 'InitializedRig', @obj.onServiceInitializedRig);
        end

    end

    methods (Access = private)

        function bindDevices(obj)
            obj.deviceListeners = {};
            for i = 1:numel(obj.devices)
                obj.deviceListeners{end + 1} = obj.addListener( ...
                    obj.devices{i}, 'background', 'PostSet', @obj.onDeviceSetBackground);
            end
        end

        function unbindDevices(obj)
            while ~isempty(obj.deviceListeners)
                obj.removeListener(obj.deviceListeners{1});
                obj.deviceListeners(1) = [];
            end
        end

        function populateTable(obj)
            n = numel(obj.devices);
            if n == 0
                obj.deviceTable.Data = {};
                return;
            end
            data = cell(n, 3);
            for i = 1:n
                d = obj.devices{i};
                data{i, 1} = d.name;
                data{i, 2} = d.background.quantity;
                data{i, 3} = d.background.displayUnits;
            end
            obj.deviceTable.Data = data;
        end

        function onCellEdit(obj, ~, evt)
            row = evt.Indices(1);
            col = evt.Indices(2);
            if col ~= 2
                return;
            end
            newVal = evt.NewData;
            if ischar(newVal) || isstring(newVal)
                newVal = str2double(newVal);
            end
            if isnan(newVal)
                % Revert
                obj.populateTable();
                return;
            end

            device = obj.devices{row};
            oldBackground = device.background;
            device.background = symphonyui.core.Measurement(newVal, device.background.displayUnits);
            try
                device.applyBackground();
            catch x
                device.background = oldBackground;
                obj.populateTable();
                uialert(obj.getFigureHandle(), x.message, 'Background Error');
                return;
            end

            % Update background for all modes if the device supports modes
            if ismethod(device, 'availableModes')
                for i = 1:numel(device.availableModes)
                    mode = device.availableModes{i};
                    b = device.getBackgroundForMode(mode);
                    device.setBackgroundForMode(mode, ...
                        symphonyui.core.Measurement(newVal, b.displayUnits));
                end
            end
        end

        function onServiceInitializedRig(obj, ~, ~)
            obj.unbindDevices();
            obj.devices = obj.configurationService.getOutputDevices();
            obj.populateTable();
            obj.bindDevices();
        end

        function onDeviceSetBackground(obj, ~, ~)
            obj.populateTable();
        end

    end

end
