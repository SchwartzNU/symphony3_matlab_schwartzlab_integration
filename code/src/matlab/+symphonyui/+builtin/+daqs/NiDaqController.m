classdef NiDaqController < symphonyui.core.DaqController
    % Manages a National Instruments DAQ interface.
    %
    % Supports single or multiple NI DAQ devices. When multiple devices are
    % specified, the first device is the synchronization master.
    %
    % Usage:
    %   controller = symphonyui.builtin.daqs.NiDaqController()              % auto-detect first device
    %   controller = symphonyui.builtin.daqs.NiDaqController('Dev1')        % single device
    %   controller = symphonyui.builtin.daqs.NiDaqController('Dev1,Dev2')   % comma-delimited
    %   controller = symphonyui.builtin.daqs.NiDaqController('Dev1;Dev2')   % semicolon-delimited
    %   controller = symphonyui.builtin.daqs.NiDaqController({'Dev1','Dev2','Dev3'})  % cell array
    
    methods
        
        function obj = NiDaqController(deviceNames)
            try
                NET.addAssembly(which('NIDAQInterface.dll'));
            catch x
                if strcmp(x.identifier, 'MATLAB:NET:CLRException:AddAssembly')
                    error('Unable to load National Instruments assembly. Are you sure you have the NI-DAQmx drivers installed?');
                end
                rethrow(x);
            end
            
            if nargin < 1
                % Auto-detect: find the first available device
                enum = Symphony.Core.EnumerableExtensions.Wrap(NI.NIDAQController.AvailableControllers());
                e = enum.GetEnumerator();
                if ~e.MoveNext()
                    error('Unable to find any National Instruments devices. Make sure your device is listed in NI MAX and try again.');
                end
                deviceNames = char(e.Current.DeviceName);
            elseif iscell(deviceNames)
                % Cell array of device names -> comma-delimited string
                deviceNames = strjoin(deviceNames, ',');
            end
            
            % deviceNames is now a string (single name or comma/semicolon-delimited)
            cobj = NI.NIDAQController(deviceNames);
            obj@symphonyui.core.DaqController(cobj);
            
            Symphony.Core.Converters.Register(Symphony.Core.Measurement.UNITLESS, Symphony.Core.Measurement.UNITLESS, Symphony.Core.ConvertProcs.Scale(1, Symphony.Core.Measurement.UNITLESS));
            Symphony.Core.Converters.Register('V', 'V', Symphony.Core.ConvertProcs.Scale(1, 'V'));
            
            obj.sampleRate = symphonyui.core.Measurement(10000, 'Hz');
            obj.sampleRateType = symphonyui.core.PropertyType('denserealdouble', 'scalar', {1000, 10000, 20000, 50000});

            obj.tryCore(@()obj.cobj.InitHardware());
            
            Symphony.Core.Converters.Register(Symphony.Core.Measurement.NORMALIZED, 'V', Symphony.Core.ConvertProcs.Scale(-obj.cobj.MinAOVoltage, obj.cobj.MaxAOVoltage, 'V'));
            Symphony.Core.Converters.Register('V', Symphony.Core.Measurement.NORMALIZED, Symphony.Core.ConvertProcs.Scale(1/(-obj.cobj.MinAIVoltage), 1/obj.cobj.MaxAIVoltage, Symphony.Core.Measurement.NORMALIZED));
        end
        
        function close(obj)
            close@symphonyui.core.DaqController(obj);
            obj.tryCore(@()obj.cobj.Dispose());
        end
        
        % function s = getStream(obj, name)
        %     s = getStream@symphonyui.core.DaqController(obj, name);
        %     if strncmp(name, 'd', 1)
        %         s = symphonyui.builtin.daqs.NiDigitalDaqStream(s.cobj);
        %     end
        % end

        function s = getStream(obj, name)
            s = getStream@symphonyui.core.DaqController(obj, name);
            if contains(name, 'port')
                s = symphonyui.builtin.daqs.NiDigitalDaqStream(s.cobj);
            end
        end
        
        function names = getDeviceNames(obj)
            % Returns the list of configured device names as a cell array.
            %   names = controller.getDeviceNames()
            %   % e.g. {'Dev1', 'Dev2', 'Dev3'}
            n = obj.cobj.DeviceNames;
            names = cell(1, n.Count);
            for i = 1:n.Count
                names{i} = char(n.Item(i - 1));
            end
        end
        
    end
    
end
