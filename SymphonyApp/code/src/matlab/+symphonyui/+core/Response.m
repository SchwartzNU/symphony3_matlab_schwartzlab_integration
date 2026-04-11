classdef Response < symphonyui.core.CoreObject
    % A Response represents a single response (i.e. the input from a single device) during an epoch.
    %
    % Response Methods:
    %   getData     - Gets a vector of the data of this response
    
    properties (SetAccess = private)
        sampleRate  % Sample rate of this response (Measurement)
    end
    
    properties (Access = private)
        dataCache
        unitConversionFactor    % cached base-to-display conversion factor
    end
    
    methods
        
        function obj = Response(cobj)
            obj@symphonyui.core.CoreObject(cobj);
        end
        
        function m = get.sampleRate(obj)
            cm = obj.cobj.SampleRate;
            if isempty(cm)
                m = [];
            else
                m = symphonyui.core.Measurement(cm);
            end
        end
        
        function tf = isStreaming(obj)
            % Returns true if this response is in streaming (ring buffer) mode.
            % In streaming mode, getData() returns only the most recent window
            % of data, not the full epoch response.
            try
                tf = logical(obj.cobj.IsStreaming);
            catch
                tf = false;
            end
        end

        function n = getTotalSampleCount(obj)
            % Total number of samples received (including evicted ring buffer data).
            try
                n = double(obj.cobj.TotalSampleCount);
            catch
                n = 0;
            end
        end

        function [q, u] = getData(obj)
            % Gets a vector of the data of this response.
            % In streaming mode, returns only the current ring buffer window.
            %
            % Uses the fast C# GetDataArray() path which returns double[]
            % directly, avoiding slow IEnumerable<IMeasurement> marshalling
            % that is extremely slow at high sample rates (20-50kHz).

            % Only use cache if the data has been finalized (i.e. the epoch
            % is complete and no more data will arrive). During acquisition,
            % the response is still accumulating data, so skip the cache.
            streaming = obj.isStreaming();
            if ~streaming && ~isempty(obj.dataCache) && obj.dataCache.finalized
                q = obj.dataCache.q;
                u = obj.dataCache.u;
                return;
            end

            % Fast path: GetDataArray returns double[] directly from C#
            % Note: GetDataArray returns base-unit quantities; we convert
            % to display units so the label from GetDataUnits matches.
            try
                netArray = obj.cobj.GetDataArray();
                if ~isempty(netArray) && netArray.Length > 0
                    q = double(netArray);
                    u = char(obj.cobj.GetDataUnits());
                    q = q * obj.getUnitConversionFactor(u);
                else
                    q = [];
                    u = '';
                end
            catch
                % Fallback to legacy LINQ path
                try
                    cdata = obj.tryCoreWithReturn(@()obj.cobj.Data);
                    if NET.invokeGenericMethod('System.Linq.Enumerable', 'Any', {'Symphony.Core.IMeasurement'}, cdata)
                        q = double(Symphony.Core.Measurement.ToQuantityArray(cdata));
                        u = char(Symphony.Core.Measurement.HomogenousDisplayUnits(cdata));
                    else
                        q = [];
                        u = '';
                    end
                catch
                    q = [];
                    u = '';
                end
            end

            % Cache the data. Mark as finalized only when the sample count
            % matches the previous call (no new data arrived = epoch is done).
            nSamples = numel(q);
            prevCount = 0;
            if ~isempty(obj.dataCache)
                prevCount = obj.dataCache.nSamples;
            end
            finalized = ~streaming && (nSamples > 0) && (nSamples == prevCount);
            obj.dataCache = struct('q', q, 'u', u, 'nSamples', nSamples, 'finalized', finalized);
        end

        function [q, u] = getFullData(obj)
            %GETFULLDATA  Get ALL accumulated data, including evicted ring buffer data.
            %   Unlike getData() which returns only the ring buffer window during
            %   streaming, getFullData() returns every sample received since the
            %   epoch started. Safe to call during CompletedEpoch handlers.
            %
            %   For non-streaming responses, this is identical to getData().
            try
                netArray = obj.cobj.GetFullDataArray();
                if ~isempty(netArray) && netArray.Length > 0
                    q = double(netArray);
                    u = char(obj.cobj.GetDataUnits());
                    q = q * obj.getUnitConversionFactor(u);
                else
                    q = [];
                    u = '';
                end
            catch
                % Fallback to regular getData
                [q, u] = obj.getData();
            end
        end

    end

    methods (Access = private)

        function factor = getUnitConversionFactor(obj, displayUnits)
            %GETUNITCONVERSIONFACTOR  Cached factor to convert base-unit values to display units.
            %   Uses a reference Measurement(1, displayUnits) to derive the
            %   ratio, e.g. 'pA' → 1/(1e-12) = 1e12.
            if ~isempty(obj.unitConversionFactor)
                factor = obj.unitConversionFactor;
                return;
            end
            factor = 1;
            if ~isempty(displayUnits)
                try
                    refM = symphonyui.core.Measurement(1, displayUnits);
                    qBase = refM.quantityInBaseUnits;
                    if qBase ~= 0
                        factor = 1 / qBase;
                    end
                catch
                end
            end
            obj.unitConversionFactor = factor;
        end

    end

end

