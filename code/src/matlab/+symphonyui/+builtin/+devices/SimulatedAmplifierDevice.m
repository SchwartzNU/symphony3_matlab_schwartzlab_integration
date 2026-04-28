classdef SimulatedAmplifierDevice < symphonyui.core.Device
    % A simulated amplifier device that does not use physical DAQ channels.
    %
    % This allows protocols that expect an amplifier device (e.g., LedPulse)
    % to run without consuming analog input/output channels. The device binds
    % to simulated DAQ streams that generate zero-valued input data and discard
    % output data.
    %
    % Works with ANY DAQ controller (NI, Heka, etc.) — the simulated stream
    % support is built into the base DAQControllerBase class.
    %
    % Usage in a rig description:
    %   daq = NiDaqController('Dev1');          % or HekaDaqController()
    %   obj.daqController = daq;
    %
    %   % Simulated amp — no physical channels used
    %   amp = SimulatedAmplifierDevice('Amp1', daq);
    %   obj.addDevice(amp);
    %
    %   % Real LED — uses a physical channel
    %   led = UnitConvertingDevice('Green LED', 'V').bindStream(daq.getStream('ao0'));
    %   obj.addDevice(led);
    %
    % The simulated amp appears identical to a real amp from the protocol's
    % perspective. Protocols like LedPulse can add stimuli and responses to it
    % without any code changes.
    
    properties (Access = private)
        outputStreamName
        inputStreamName
    end
    
    methods
        
        function obj = SimulatedAmplifierDevice(name, daq, units)
            import symphonyui.core.*;
            
            if nargin < 3
                units = 'V';
            end
            
            safeName = lower(regexprep(name, '\W', ''));
            outName = ['sim_' safeName '_ao'];
            inName  = ['sim_' safeName '_ai'];
            
            % Add simulated streams. AddSimulatedStreams takes 3 strings —
            % primitives that MATLAB's bridge can pass through cleanly.
            daq.tryCore(@()daq.cobj.AddSimulatedStreams(outName, inName, units));

            % SetSimulatedStreamSampleRates(daq.cobj.SampleRate) requires
            % passing an IMeasurement back into .NET, which MATLAB's macOS
            % .NET Core bridge can't do (the inheritance chain is missing
            % so values can't be boxed). MatlabInterop.InvokeWithOwnProperty
            % keeps the value entirely on the .NET side.
            symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                'InvokeWithOwnProperty', daq.cobj, 'SetSimulatedStreamSampleRates', 'SampleRate');

            % Create the device server-side via MatlabInterop. Constructing
            % Symphony.Core.UnitConvertingExternalDevice from MATLAB with a
            % Symphony.Core.Measurement arg fails for the same reason.
            cobj = symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                'CreateUnitConvertingExternalDevice', name, 'Simulated', 0.0, units);

            % MeasurementConversionTarget is a string — direct assignment OK.
            cobj.MeasurementConversionTarget = units;

            % Clock is interface-typed (IClock). Use CopyProperty to keep
            % the value on the .NET side.
            symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                'CopyProperty', daq.cobj, 'Clock', cobj, 'Clock');

            obj@symphonyui.core.Device(cobj);
            
            obj.bindStream(daq.getStream(outName));
            obj.bindStream(daq.getStream(inName));
            
            obj.outputStreamName = outName;
            obj.inputStreamName = inName;
        end
        
    end
    
end
