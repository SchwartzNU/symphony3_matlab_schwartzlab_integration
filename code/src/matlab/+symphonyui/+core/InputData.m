classdef InputData < symphonyui.core.IoData
    
    methods
        
        function obj = InputData(quantities, units, sampleRate)
            cdata = symphonyui.core.callNetStatic('Symphony.Core.Measurement', 'FromArray', quantities, units);
            crate = sampleRate.cobj;
            cobj = symphonyui.core.createNetObj('Symphony.Core.InputData', cdata, crate, System.DateTimeOffset.Now);
            obj@symphonyui.core.IoData(cobj);
        end
        
    end
    
end

