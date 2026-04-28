classdef HekaSimulationDaqController < symphonyui.builtin.daqs.SimulationDaqController
    % Manages a simulated HEKA (InstruTECH) DAQ interface (requires no attached hardware).

    methods

        function obj = HekaSimulationDaqController()
            % Use createNetObj for constructor calls so we go through the
            % reflection-based fallback on macOS/Linux, where MATLAB's
            % .NET Core name resolver does not reliably register type
            % names used only inside class methods. Constructor calls
            % like `Symphony.Core.DAQInputStream(...)` fail with
            % "Unable to resolve the name ..." on those platforms even
            % when the assembly is loaded and the type is exported.
            for i = 1:16
                name = ['ai' num2str(i-1)];
                cstr = symphonyui.core.createNetObj('Symphony.Core.DAQInputStream', name, obj.cobj);
                cstr.MeasurementConversionTarget = 'V';
                symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'CopyProperty', obj.cobj, 'Clock', cstr, 'Clock');
                obj.addStream(symphonyui.core.DaqStream(cstr));
            end

            for i = 1:8
                name = ['ao' num2str(i-1)];
                cstr = symphonyui.core.createNetObj('Symphony.Core.DAQOutputStream', name, obj.cobj);
                cstr.MeasurementConversionTarget = 'V';
                symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'CopyProperty', obj.cobj, 'Clock', cstr, 'Clock');
                obj.addStream(symphonyui.core.DaqStream(cstr));
            end

            for i = 1:6
                name = ['diport' num2str(i-1)];
                cstr = symphonyui.core.createNetObj('Symphony.Core.DAQInputStream', name, obj.cobj);
                cstr.MeasurementConversionTarget = Symphony.Core.Measurement.UNITLESS;
                symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'CopyProperty', obj.cobj, 'Clock', cstr, 'Clock');
                obj.addStream(symphonyui.core.DaqStream(cstr));
            end

            for i = 1:6
                name = ['doport' num2str(i-1)];
                cstr = symphonyui.core.createNetObj('Symphony.Core.DAQOutputStream', name, obj.cobj);
                cstr.MeasurementConversionTarget = Symphony.Core.Measurement.UNITLESS;
                symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'CopyProperty', obj.cobj, 'Clock', cstr, 'Clock');
                obj.addStream(symphonyui.core.DaqStream(cstr));
            end

            % callNetStatic for the same reason createNetObj is used above:
            % macOS/Linux .NET Core name resolution does not reliably
            % resolve `Symphony.Core.Converters.Register(...)` or
            % `Symphony.Core.ConvertProcs.Scale(...)` dotted-name static
            % method calls inside class methods.
            unitless = Symphony.Core.Measurement.UNITLESS;
            normalized = Symphony.Core.Measurement.NORMALIZED;
            symphonyui.core.callNetStatic('Symphony.Core.Converters', 'Register', unitless, unitless, ...
                symphonyui.core.callNetStatic('Symphony.Core.ConvertProcs', 'Scale', 1, unitless));
            symphonyui.core.callNetStatic('Symphony.Core.Converters', 'Register', 'V', 'V', ...
                symphonyui.core.callNetStatic('Symphony.Core.ConvertProcs', 'Scale', 1, 'V'));
            symphonyui.core.callNetStatic('Symphony.Core.Converters', 'Register', normalized, 'V', ...
                symphonyui.core.callNetStatic('Symphony.Core.ConvertProcs', 'Scale', 10.24, 'V'));
            symphonyui.core.callNetStatic('Symphony.Core.Converters', 'Register', 'V', normalized, ...
                symphonyui.core.callNetStatic('Symphony.Core.ConvertProcs', 'Scale', 1/10.24, normalized));

            obj.sampleRate = symphonyui.core.Measurement(10000, 'Hz');
            obj.sampleRateType = symphonyui.core.PropertyType('denserealdouble', 'scalar', {1000, 10000, 20000, 50000});

            obj.simulation = symphonyui.builtin.simulations.Loopback();
        end

        function s = getStream(obj, name)
            newName = [];
            if strncmp(name, 'ANALOG_IN.', 10)
                newName = ['ai' name(11:end)];
            elseif strncmp(name, 'ANALOG_OUT.', 11)
                newName = ['ao' name(12:end)];
            elseif strncmp(name, 'DIGITAL_IN.', 11)
                newName = ['diport' name(12:end)];
            elseif strncmp(name, 'DIGITAL_OUT.', 12)
                newName = ['doport' name(13:end)];
            end
            
            if ~isempty(newName)
                warning('The stream name %s is deprecated. Use %s.', name, newName);
                name = newName;
            end
            
            s = getStream@symphonyui.core.DaqController(obj, name);
            if strncmp(name, 'd', 1)
                s = symphonyui.builtin.daqs.HekaSimulationDigitalDaqStream(s.cobj);
            end
        end

    end

    methods (Access = protected)

        function setSampleRate(obj, measurement)
            streams = obj.getStreams();
            for i = 1:numel(streams)
                streams{i}.sampleRate = measurement;
            end
            symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                'SetMeasurementProperty', obj.cobj, 'SampleRate', ...
                measurement.quantity, measurement.baseUnits);
        end

    end

end
