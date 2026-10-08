classdef Measurement < symphonyui.core.CoreObject
    % A Measurements represents a quantity and a unit of measure.

    properties (Constant)
        UNITLESS = '_unitless_'     % char(Symphony.Core.Measurement.UNITLESS);
        NORMALIZED = '_normalized_' % char(Symphony.Core.Measurement.NORMALIZED);
    end

    properties (SetAccess = private)
        quantity                % Quantity of this measurement
        quantityInBaseUnits     % Quantity expressed in base units (e.g. 1 mV would be 1*10^-3 V)
        baseUnits               % SI units of this measurement
        displayUnits            % Display units accounting for exponent (e.g. 1x10^-3 V has base units of 'V' but display units of 'mV')
    end

    properties (Access = private)
        % Cached primitives. On macOS .NET Core MATLAB's bridge can
        % silently fail when reading properties off a wrapped .NET
        % object that has lost its inheritance chain (every type ends
        % up with only `handle` as its parent in MATLAB's view), so we
        % keep the construction-time primitives around. They're also
        % what we need to pass back into .NET via MatlabInterop helpers.
        cachedQuantity = []
        cachedBaseUnits = ''
    end

    methods

        function obj = Measurement(quantity, units)
            % Two construction paths:
            %   Measurement(quantity, units)          -- both primitives
            %   Measurement(cobj)                     -- wrap a .NET Measurement
            %   Measurement(cobj, units)              -- wrap, units known
            % The third form exists because on macOS .NET Core MATLAB's
            % introspection of Symphony.Core.Measurement is incomplete:
            % it can read .Quantity but errors on .BaseUnits (despite
            % both being public properties in C#). Callers that know
            % the units (e.g. sampleRate is always 'Hz') should pass
            % them explicitly to avoid the broken read.
            if isa(quantity, 'Symphony.Core.Measurement')
                cobj = quantity;
                % Use System.Decimal.ToDouble — Windows (.NET Framework)
                % does not auto-convert System.Decimal to MATLAB double,
                % so `double(cobj.Quantity)` raises "Conversion to double
                % from System.Decimal is not possible". Mac would
                % auto-convert, but the explicit conversion works on
                % both platforms.
                cachedQty = System.Decimal.ToDouble(cobj.Quantity);
                if nargin >= 2 && ~isempty(units)
                    cachedUnits = char(units);
                else
                    try
                        cachedUnits = char(cobj.BaseUnits);
                    catch
                        cachedUnits = '';
                    end
                end
            else
                cobj = symphonyui.core.createNetObj('Symphony.Core.Measurement', quantity, units);
                cachedQty = double(quantity);
                cachedUnits = char(units);
            end

            obj@symphonyui.core.CoreObject(cobj);
            obj.cachedQuantity = cachedQty;
            obj.cachedBaseUnits = cachedUnits;
        end

        function q = get.quantity(obj)
            if ~isempty(obj.cachedQuantity)
                q = obj.cachedQuantity;
            else
                q = System.Decimal.ToDouble(obj.cobj.Quantity);
            end
        end

        function q = get.quantityInBaseUnits(obj)
            % When constructed from base-unit primitives (exponent 0)
            % QuantityInBaseUnits == Quantity, so the cache is correct.
            % All Symphony Measurement constructions go through that
            % path; the .NET fallback is only for objects we wrapped
            % without an explicit cache (rare, and on macOS the
            % Decimal property read here may also fail on the bridge —
            % the try/catch keeps that case from killing callers).
            % Ask the .NET object: for a prefixed unit the base quantity
            % differs from the quantity (1 mV -> 0.001 V). Returning the
            % cached quantity here made Response.getData hand every figure
            % base-unit values (volts, amperes) labelled mV / pA, which broke
            % spike thresholds and amplitudes (Rig A, 2026-10-08). The cache
            % is only a fallback for bridges where the Decimal read fails.
            try
                q = System.Decimal.ToDouble(obj.cobj.QuantityInBaseUnits);
            catch
                q = obj.cachedQuantity;
            end
        end

        function u = get.baseUnits(obj)
            if ~isempty(obj.cachedBaseUnits)
                u = obj.cachedBaseUnits;
            else
                u = char(obj.cobj.BaseUnits);
            end
        end

        function u = get.displayUnits(obj)
            u = char(obj.cobj.DisplayUnits);
        end

    end

end
