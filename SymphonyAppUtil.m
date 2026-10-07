classdef SymphonyAppUtil
    methods (Static)
        function n = getNetCount(c)
            if isempty(c)
                n = 0;
                return;
            end
            % Prefer Count (List<T>, IList, IReadOnlyList) — Length is for System.Array only.
            try
                n = double(c.Count);
                return;
            catch
            end
            try
                n = double(c.Length);
                return;
            catch
            end
            error('Unsupported collection type from .NET');
        end

        function item = getNetItem(c, oneBasedIndex)
            try
                item = c(oneBasedIndex);
                return;
            catch
            end
            try
                item = c.Item(oneBasedIndex - 1);
                return;
            catch
            end
            error('Unable to index .NET collection item');
        end

        function v = netDoubleVector(netArr)
            % Convert System.Double[] / IList<double> to 1×N double for plotting.
            if isempty(netArr)
                v = zeros(1, 0);
                return;
            end
            try
                v = double(netArr);
                v = v(:)';
                return;
            catch
            end
            try
                n = SymphonyAppUtil.getNetCount(netArr);
                v = zeros(1, n);
                for i = 1:n
                    v(i) = double(SymphonyAppUtil.getNetItem(netArr, i));
                end
            catch
                v = zeros(1, 0);
            end
        end

        function out = netToMatlabValue(in)
            if isempty(in)
                out = [];
                return;
            end
            try
                if isa(in, 'System.Text.Json.JsonElement')
                    out = SymphonyAppUtil.jsonElementToMatlab(in);
                    return;
                end
            catch
            end
            try
                if isa(in, 'System.String')
                    out = char(in);
                    return;
                end
            catch
            end
            out = in;
        end

        function out = jsonElementToMatlab(je)
            try
                kind = char(je.ValueKind.ToString());
            catch
                out = je;
                return;
            end
            switch kind
                case 'String'
                    out = char(je.GetString());
                case 'Number'
                    try
                        out = double(je.GetDouble());
                    catch
                        out = str2double(char(je.GetRawText()));
                    end
                case 'True'
                    out = true;
                case 'False'
                    out = false;
                case 'Null'
                    out = [];
                case 'Array'
                    arr = je.EnumerateArray();
                    vals = {};
                    while arr.MoveNext()
                        vals{end + 1} = SymphonyAppUtil.jsonElementToMatlab(arr.Current); %#ok<AGROW>
                    end
                    out = vals;
                otherwise
                    out = char(je.GetRawText());
            end
        end

        function v = coerceValue(raw, primitiveType)
            t = lower(string(primitiveType));
            % Symphony 2 / jide type names: denserealdouble, sparsecomplexsingle, ...
            if contains(t, "double")
                t = "double";
            elseif contains(t, "single")
                t = "single";
            end
            switch t
                case "double"
                    if ischar(raw) || isstring(raw)
                        v = SymphonyAppUtil.evalNumericExpr(raw);
                    else
                        v = double(raw);
                    end
                    if isempty(v) || (isscalar(v) && isnan(v)), error('Value must be numeric'); end
                case {"single"}
                    if ischar(raw) || isstring(raw)
                        d = SymphonyAppUtil.evalNumericExpr(raw);
                    else
                        d = double(raw);
                    end
                    if isempty(d) || (isscalar(d) && isnan(d)), error('Value must be numeric'); end
                    v = single(d);
                case {"int8","int16","int32","int64","uint8","uint16","uint32","uint64"}
                    if ischar(raw) || isstring(raw)
                        d = SymphonyAppUtil.evalNumericExpr(raw);
                    else
                        d = double(raw);
                    end
                    if isempty(d) || (isscalar(d) && isnan(d)), error('Value must be numeric'); end
                    castFcn = str2func(char(t));
                    v = castFcn(round(d));
                case {"logical","bool","boolean"}
                    if islogical(raw)
                        v = raw;
                    elseif isnumeric(raw)
                        v = raw ~= 0;
                    else
                        s = lower(strtrim(string(raw)));
                        if any(strcmp(s, ["true","1","yes","on"]))
                            v = true;
                        elseif any(strcmp(s, ["false","0","no","off"]))
                            v = false;
                        else
                            error('Value must be true/false');
                        end
                    end
                case {"char","string"}
                    v = char(string(raw));
                otherwise
                    v = raw;
            end
        end

        function v = evalNumericExpr(raw)
            %EVALNUMERICEXPR  Evaluate a string as a MATLAB numeric expression.
            %   Supports arithmetic (60*9*1000+59000), ranges (1:5), arrays
            %   ([1,2,3]), and built-in math functions (round, sqrt, etc.).
            %   Falls back to str2double for simple numeric strings.
            %
            %   Returns NaN if the expression is invalid or produces a
            %   non-numeric result.
            raw = strtrim(char(raw));
            if isempty(raw)
                v = NaN;
                return;
            end

            % First try str2double (fast path for simple numbers)
            v = str2double(raw);
            if ~isnan(v)
                return;
            end

            % Try str2num which evaluates MATLAB expressions.
            % str2num uses eval internally but is standard MATLAB practice
            % for numeric input parsing (used in the old Symphony2).
            try
                v = str2num(raw); %#ok<ST2NM>
                if isempty(v)
                    v = NaN;
                elseif ~isnumeric(v)
                    v = NaN;
                end
            catch
                v = NaN;
            end
        end

        function d = valueToDisplay(v)
            if islogical(v)
                if v
                    d = 'true';
                else
                    d = 'false';
                end
            elseif isnumeric(v) && isscalar(v)
                d = num2str(v);
            elseif ischar(v)
                d = v;
            elseif isstring(v) && isscalar(v)
                d = char(v);
            elseif isnumeric(v)
                d = mat2str(v);
            elseif iscell(v)
                parts = cellfun(@(x) char(string(x)), v, 'UniformOutput', false);
                d = strjoin(parts, ', ');
            else
                % Objects, enums, structs, etc. — always return char
                try
                    d = char(string(v));
                catch
                    d = class(v);
                end
            end
        end

        function s = onOff(tf)
            if tf
                s = 'on';
            else
                s = 'off';
            end
        end
    end
end
