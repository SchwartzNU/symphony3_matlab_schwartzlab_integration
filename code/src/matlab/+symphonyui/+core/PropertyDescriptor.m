classdef PropertyDescriptor < matlab.mixin.SetGet %#ok<*MCSUP>
    % A PropertyDescriptor describes a single property within a protocol or description. A PropertyDescriptor can be
    % used to restrict a property's type or domain, specify a property's category, set a property to be hidden or
    % read-only, and more.

    properties
        name            % Short name of the property
        value           % Current value of the property
        type            % Type constraints the property value must conform to (PropertyType)
        category        % Name of the category the property should be grouped into
        displayName     % Descriptive name of the property
        description     % Detailed description of the property
        isReadOnly      % Indicates if the property is read only
        isHidden        % Indicates if the property is hidden
        isPreferred     % Indicates if the property is preferred
        isRemovable     % Indicates if the property is removable
    end

    methods

        function obj = PropertyDescriptor(name, value, varargin)
            if isobject(value) && ~isa(value, 'symphonyui.core.PropertyType')
                error('Value of type object are not supported');
            end
            obj.name = name;
            obj.value = value;
            obj.type = [];
            obj.category = '';
            obj.displayName = appbox.humanize(name);
            obj.description = '';
            obj.isReadOnly = false;
            obj.isHidden = false;
            obj.isPreferred = false;
            obj.isRemovable = false;
            if nargin > 2
                obj.set(varargin{:});
            end
        end

        function set.value(obj, v)
            if isobject(v) && ~isa(v, 'symphonyui.core.PropertyType')
                error('Value of type object are not supported');
            end
            obj.value = v;
        end

        function p = findByName(array, name)
            p = [];
            for i = 1:numel(array)
                if strcmp(name, array(i).name)
                    p = array(i);
                    return;
                end
            end
        end

        function m = toMap(array)
            m = containers.Map();
            for i = 1:numel(array)
                if ~array(i).isHidden
                    m(array(i).name) = array(i).value;
                end
            end
        end

        function s = saveobj(obj)
            s = struct();
            s.name = obj.name;
            s.value = obj.value;
            % Save type as a plain struct with primitiveType/shape/domain
            % so that Symphony2's loadobj can reconstruct it via
            % uiextras.jide.PropertyType(t.primitiveType, t.shape, t.domain).
            % IMPORTANT: Never save type as [] — Symphony 2's set.type does
            % t.primitiveType which crashes on []. Always provide a valid struct.
            % Symphony 2 rebuilds the descriptor through uiextras.jide.PropertyGridField,
            % which rejects a type whose shape does not fit the value ("Setting type
            % ... would invalidate current property value") and then leaves the
            % descriptor unusable (name empty). So the saved shape is always derived
            % from the actual value, and 'double' is written as 'denserealdouble' etc.
            v = obj.value;
            inferred = symphonyui.core.PropertyType.autoDiscover(v);
            if ~isempty(obj.type) && isa(obj.type, 'symphonyui.core.PropertyType')
                pt = char(obj.type.primitiveType);
                if any(strcmp(pt, {'double', 'single'}))
                    pt = inferred.primitiveType;        % jide naming
                end
                sh = char(obj.type.shape);
                if ~isempty(v) && ~strcmp(sh, inferred.shape) ...
                        && ~(strcmp(sh, 'row') && strcmp(inferred.shape, 'scalar') && ischar(v))
                    sh = inferred.shape;
                end
                dom = obj.type.domain;
                if isempty(dom), dom = {}; end
                s.type = struct('primitiveType', pt, 'shape', sh, 'domain', {dom});
            else
                s.type = struct('primitiveType', inferred.primitiveType, 'shape', inferred.shape, 'domain', {{}});
            end
            s.category = obj.category;
            s.displayName = obj.displayName;
            s.description = obj.description;
            s.isReadOnly = obj.isReadOnly;
            s.isHidden = obj.isHidden;
            s.isPreferred = obj.isPreferred;
            s.isRemovable = obj.isRemovable;
        end

        function tf = isequal(obj, other)
            tf = isa(other, 'symphonyui.core.PropertyDescriptor') ...
                && strcmp(obj.name, other.name) ...
                && isequal(obj.value, other.value) ...
                && isequal(obj.isRemovable, other.isRemovable);
        end

    end

    methods (Static)

        function obj = loadobj(s)
            if isstruct(s)
                % Reconstruct PropertyType from saved struct if needed
                typeVal = s.type;
                if isstruct(typeVal) && isfield(typeVal, 'primitiveType')
                    try
                        typeVal = symphonyui.core.PropertyType( ...
                            typeVal.primitiveType, typeVal.shape, typeVal.domain);
                    catch
                        typeVal = [];
                    end
                end
                obj = symphonyui.core.PropertyDescriptor(s.name, s.value, ...
                    'type', typeVal, ...
                    'category', s.category, ...
                    'displayName', s.displayName, ...
                    'description', s.description, ...
                    'isReadOnly', s.isReadOnly, ...
                    'isHidden', s.isHidden, ...
                    'isPreferred', s.isPreferred, ...
                    'isRemovable', s.isRemovable);
            end
        end

        function obj = fromProperty(handle, property)
            mpo = findprop(handle, property);
            if isempty(mpo)
                error([property ' not found on handle']);
            end

            % Extract description from property comment
            desc = '';
            try
                if ~isempty(mpo.Description)
                    desc = mpo.Description;
                end
            catch
            end

            obj = symphonyui.core.PropertyDescriptor(mpo.Name, handle.(mpo.Name), ...
                'description', desc, ...
                'isReadOnly', mpo.Constant || ~strcmp(mpo.SetAccess, 'public') || (mpo.Dependent && isempty(mpo.SetMethod)));

            mto = findprop(handle, [property 'Type']);
            if ~isempty(mto) && mto.Hidden && isa(handle.(mto.Name), 'symphonyui.core.PropertyType')
                obj.type = handle.(mto.Name);
            end
        end

    end

end
