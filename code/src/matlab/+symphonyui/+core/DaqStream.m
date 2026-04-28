classdef DaqStream < symphonyui.core.CoreObject
    % A DaqStream represents a hardware channel of a DAQ device.
    
    properties (SetAccess = private)
        name    % Name of this stream
        active  % Indicates if this stream has an associated device   
    end
    
    properties
        sampleRate                      % Sample rate of this stream (Measurement)
        measurementConversionTarget     % What is this stream converting Measurements to? (e.g. volts, ohms, etc.) 
    end
    
    methods
        
        function obj = DaqStream(cobj)
            obj@symphonyui.core.CoreObject(cobj);
        end
        
        function n = get.name(obj)
            n = char(obj.cobj.Name);
        end
        
        function tf = get.active(obj)
            tf = obj.cobj.Active;
        end
        
        function m = get.sampleRate(obj)
            cm = obj.cobj.SampleRate;
            if isempty(cm)
                m = [];
            else
                % See DaqController.get.sampleRate — explicit units to
                % bypass the macOS BaseUnits-read bridge gap.
                m = symphonyui.core.Measurement(cm, 'Hz');
            end
        end
        
        function set.sampleRate(obj, measurement)
            if isempty(measurement)
                error('symphonyui:DaqStream:sampleRate', ...
                    'Clearing sampleRate is not supported on this platform');
            end
            % Pass primitives through to the C# helper which constructs
            % the Measurement and assigns the property server-side.
            % MATLAB's macOS .NET Core bridge can't pass an existing
            % Symphony.Core.Measurement back into .NET as IMeasurement
            % (the inheritance chain is missing in MATLAB's view).
            symphonyui.core.callNetStatic('Symphony.Core.MatlabInterop', ...
                'SetMeasurementProperty', obj.cobj, 'SampleRate', ...
                measurement.quantity, measurement.baseUnits);
        end
        
        function t = get.measurementConversionTarget(obj)
            t = char(obj.cobj.MeasurementConversionTarget);
        end
        
        function set.measurementConversionTarget(obj, t)
            obj.cobj.MeasurementConversionTarget = t;
        end
        
    end
    
end

