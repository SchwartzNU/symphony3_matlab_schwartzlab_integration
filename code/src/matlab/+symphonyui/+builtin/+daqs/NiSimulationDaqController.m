classdef NiSimulationDaqController < symphonyui.builtin.daqs.SimulationDaqController
    % Manages a simulated National Instruments DAQ interface (requires no attached hardware).

    methods

        function obj = NiSimulationDaqController()
            % See HekaSimulationDaqController.m for rationale — using
            % createNetObj so constructor calls survive macOS/Linux
            % .NET Core name resolution.
            for i = 1:32
                name = ['ai' num2str(i-1)];
                cstr = symphonyui.core.createNetObj('Symphony.Core.DAQInputStream', name, obj.cobj);
                cstr.MeasurementConversionTarget = 'V';
                symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'CopyProperty', obj.cobj, 'Clock', cstr, 'Clock');
                obj.addStream(symphonyui.core.DaqStream(cstr));
            end

            for i = 1:4
                name = ['ao' num2str(i-1)];
                cstr = symphonyui.core.createNetObj('Symphony.Core.DAQOutputStream', name, obj.cobj);
                cstr.MeasurementConversionTarget = 'V';
                symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'CopyProperty', obj.cobj, 'Clock', cstr, 'Clock');
                obj.addStream(symphonyui.core.DaqStream(cstr));
            end

            for i = 1:3
                name = ['diport' num2str(i-1)];
                cstr = symphonyui.core.createNetObj('Symphony.Core.DAQInputStream', name, obj.cobj);
                cstr.MeasurementConversionTarget = Symphony.Core.Measurement.UNITLESS;
                symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'CopyProperty', obj.cobj, 'Clock', cstr, 'Clock');
                obj.addStream(symphonyui.core.DaqStream(cstr));
            end

            for i = 1:3
                name = ['doport' num2str(i-1)];
                cstr = symphonyui.core.createNetObj('Symphony.Core.DAQOutputStream', name, obj.cobj);
                cstr.MeasurementConversionTarget = Symphony.Core.Measurement.UNITLESS;
                symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                    'CopyProperty', obj.cobj, 'Clock', cstr, 'Clock');
                obj.addStream(symphonyui.core.DaqStream(cstr));
            end

            % See HekaSimulationDaqController for rationale — callNetStatic
            % routes through reflection, required on macOS/Linux.
            unitless = Symphony.Core.Measurement.UNITLESS;
            normalized = Symphony.Core.Measurement.NORMALIZED;
            symphonyui.core.callNetStatic('Symphony.Core.Converters', 'Register', unitless, unitless, ...
                symphonyui.core.callNetStatic('Symphony.Core.ConvertProcs', 'Scale', 1, unitless));
            symphonyui.core.callNetStatic('Symphony.Core.Converters', 'Register', 'V', 'V', ...
                symphonyui.core.callNetStatic('Symphony.Core.ConvertProcs', 'Scale', 1, 'V'));
            symphonyui.core.callNetStatic('Symphony.Core.Converters', 'Register', normalized, 'V', ...
                symphonyui.core.callNetStatic('Symphony.Core.ConvertProcs', 'Scale', 10, 'V'));
            symphonyui.core.callNetStatic('Symphony.Core.Converters', 'Register', 'V', normalized, ...
                symphonyui.core.callNetStatic('Symphony.Core.ConvertProcs', 'Scale', 1/10, normalized));

            obj.sampleRate = symphonyui.core.Measurement(10000, 'Hz');
            obj.sampleRateType = symphonyui.core.PropertyType('denserealdouble', 'scalar', {1000, 10000, 20000, 50000});

            obj.simulation = symphonyui.builtin.simulations.Loopback();
        end

        function s = getStream(obj, name)
            s = getStream@symphonyui.core.DaqController(obj, name);
            if strncmp(name, 'd', 1)
                s = symphonyui.builtin.daqs.NiSimulationDigitalDaqStream(s.cobj);
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
