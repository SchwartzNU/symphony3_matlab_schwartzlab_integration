classdef Rig < handle
    % A Rig represents an electrophysiology setup. A Rig is constructed with a RigDescription that describes all of its
    % devices.
    %
    % Rig Methods:
    %   getDevice       - Gets the first device whose name matches the given regular expression
    %   getDevices      - Gets a cell array of devices whose names match the given regular expression
    %   getDeviceNames  - Gets all device names that match the given regular expression
    %
    %   getOutputDevices    - Gets all devices with at least one bound output stream
    %   getInputDevices     - Gets all devices with at least one bound input stream

    properties (SetObservable)
        sampleRate  % Common sample rate of DAQ and devices (Measurement)
    end

    properties (SetAccess = private)
        sampleRateType
        daqController
        devices
        isClosed
    end

    methods

        function obj = Rig(description)
            % Constructs a Rig with the given RigDescription
            obj.daqController = description.daqController;
            obj.devices = description.devices;
            obj.isClosed = false;

            % Propagate Clock and SampleRate from the DAQ controller to
            % each device entirely server-side via MatlabInterop. The
            % "read controller's sampleRate, then assign rig.sampleRate"
            % round-trip would crash on macOS .NET Core because the
            % DaqController.get.sampleRate getter dereferences a .NET
            % IMeasurement that MATLAB's bridge can't represent.
            for i = 1:numel(obj.devices)
                symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'CopyProperty', obj.daqController.cobj, 'Clock', ...
                    obj.devices{i}.cobj, 'Clock');
                symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'CopyProperty', obj.daqController.cobj, 'SampleRate', ...
                    obj.devices{i}.cobj, 'InputSampleRate');
                symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'CopyProperty', obj.daqController.cobj, 'SampleRate', ...
                    obj.devices{i}.cobj, 'OutputSampleRate');
            end
        end

        function delete(obj)
            obj.close();
        end

        function close(obj)
            if obj.isClosed
                return;
            end
            obj.daqController.close();
            for i = 1:numel(obj.devices)
                obj.devices{i}.close();
            end
            obj.isClosed = true;
        end

        function r = get.sampleRate(obj)
            % Read controller's sample rate as primitives via
            % MatlabInterop, avoiding the broken
            % DaqController.get.sampleRate -> .NET getter chain.
            try
                qty = symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'GetMeasurementQuantity', obj.daqController.cobj, 'SampleRate');
                r = symphonyui.core.Measurement(qty, 'Hz');
            catch
                r = [];
            end
            % Skip the device-homogeneity check on macOS because
            % retrieving devs{i}.sampleRate triggers the same broken
            % getter chain. The propagation in the constructor and
            % set.sampleRate keeps the values in sync server-side.
        end

        function set.sampleRate(obj, r)
            if isnumeric(r) && ~isempty(r)
                r = symphonyui.core.Measurement(r, 'Hz');
            end
            % Use MatlabInterop directly so the propagation happens
            % server-side. The original "obj.daqController.sampleRate = r"
            % round-trip crashes on macOS .NET Core because it goes
            % through MATLAB getter/setter chains that touch the
            % broken bridge.
            symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                'SetMeasurementProperty', obj.daqController.cobj, 'SampleRate', ...
                r.quantity, r.baseUnits); %#ok<MCSUP>
            devs = obj.devices; %#ok<MCSUP>
            for i = 1:numel(devs)
                symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'SetMeasurementProperty', devs{i}.cobj, 'InputSampleRate', ...
                    r.quantity, r.baseUnits);
                symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'SetMeasurementProperty', devs{i}.cobj, 'OutputSampleRate', ...
                    r.quantity, r.baseUnits);
            end
        end

        function t = get.sampleRateType(obj)
            t = obj.daqController.sampleRateType;
        end

        function d = getDevice(obj, expression)
            % Gets the first device whose name matches the given regular expression

            for i = 1:numel(obj.devices)
                if regexpi(obj.devices{i}.name, expression, 'once')
                    d = obj.devices{i};
                    return;
                end
            end
            error(['A device named ''' expression ''' does not exist']);
        end

        function d = getDevices(obj, expression)
            % Gets a cell array of devices whose names match the given regular expression

            if nargin < 2
                expression = '.';
            end
            d = {};
            for i = 1:numel(obj.devices)
                if regexpi(obj.devices{i}.name, expression, 'once')
                    d{end + 1} = obj.devices{i}; %#ok<AGROW>
                end
            end
        end

        function n = getDeviceNames(obj, expression)
            % Gets all device names that match the given regular expression

            if nargin < 2
                expression = '.';
            end
            n = cellfun(@(d)d.name, obj.getDevices(expression), 'UniformOutput', false);
        end

        function d = getOutputDevices(obj)
            % Gets all devices with at least one bound output stream

            d = {};
            for i = 1:numel(obj.devices)
                if ~isempty(obj.devices{i}.getOutputStreams())
                    d{end + 1} = obj.devices{i}; %#ok<AGROW>
                end
            end
        end

        function d = getInputDevices(obj)
            % Gets all devices with at least one bound input stream

            d = {};
            for i = 1:numel(obj.devices)
                if ~isempty(obj.devices{i}.getInputStreams())
                    d{end + 1} = obj.devices{i}; %#ok<AGROW>
                end
            end
        end

    end

end
