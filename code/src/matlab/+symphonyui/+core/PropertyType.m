classdef PropertyType < matlab.mixin.SetGet %#ok<*MCSUP>
    % A PropertyType encapsulates the primitive type, shape and domain constraints on a property value.
    %
    % Examples:
    %   PropertyType('denserealsingle', 'scalar')
    %       Creates a non-sparse single real scalar with unrestricted value
    %   PropertyType('denserealdouble', 'scalar', [-1, 1])
    %       Creates a non-sparse double real scalar with value in range -1 to 1
    %   PropertyType('char', 'row', {'spring', 'summer', 'fall', 'winter'})
    %       Creates a character array which may be either be 'spring', 'summer', 'fall' or 'winter'
    %   PropertyType('logical', 'column', {'A', 'B', 'C'})
    %       Creates a set whose elements are 'A', 'B' and 'C'

    properties
        primitiveType   % Underlying Matlab type for the property
        shape           % Expected dimension for the property
        domain          % Domain of possible property values (cell array for enum, numeric range, etc.)
    end

    methods

        function obj = PropertyType(primitiveType, shape, domain)
            if nargin < 1, primitiveType = 'char'; end
            if nargin < 2, shape = 'row'; end
            if nargin < 3, domain = []; end
            if strcmp(primitiveType, 'object')
                error('Type of object is not supported');
            end
            obj.primitiveType = primitiveType;
            obj.shape = shape;
            obj.domain = domain;
        end

        function tf = canAccept(obj, value)
            % Check whether value satisfies the type constraints.
            tf = true;
            if isempty(obj.domain)
                return;
            end
            if iscell(obj.domain)
                % Enumerated domain
                tf = any(strcmp(value, obj.domain));
            elseif isnumeric(obj.domain) && numel(obj.domain) == 2
                % Numeric range [lo hi]
                tf = isnumeric(value) && isscalar(value) ...
                    && value >= obj.domain(1) && value <= obj.domain(2);
            end
        end

        function s = saveobj(obj)
            s.primitiveType = obj.primitiveType;
            s.shape = obj.shape;
            s.domain = obj.domain;
        end

    end

    methods (Static)

        function obj = loadobj(s)
            if isstruct(s)
                obj = symphonyui.core.PropertyType(s.primitiveType, s.shape, s.domain);
            end
        end

        function t = autoDiscover(value)
            if islogical(value)
                t = symphonyui.core.PropertyType('logical', 'scalar');
            elseif isnumeric(value)
                t = symphonyui.core.PropertyType(class(value), 'scalar');
            elseif ischar(value) || isstring(value)
                t = symphonyui.core.PropertyType('char', 'row');
            else
                t = symphonyui.core.PropertyType('char', 'row');
            end
        end

    end

end
