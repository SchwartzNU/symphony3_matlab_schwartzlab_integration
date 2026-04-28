function json = discoverRigs(searchPaths)
    %CSBRIDGE.DISCOVERRIGS  Return JSON list of available rig descriptions.
    %
    %   json = csbridge.discoverRigs()
    %   json = csbridge.discoverRigs({'/path/with/+rigs', '/another'})
    %
    %   Output is a JSON-encoded array of objects:
    %     [{"className":"common.rigs.SimulationTest","displayName":"Simulation Test"}, ...]
    %
    %   Returning JSON instead of a struct array sidesteps the MATLAB
    %   Engine API's RuntimeValue marshaling for cell/struct arrays —
    %   the C# side just gets a string and JsonSerializer.Deserialize's
    %   it into a List<RigDescriptor>.

    if nargin < 1 || isempty(searchPaths)
        searchPaths = csbridge.getSearchPaths();
    end
    fprintf('csbridge.discoverRigs: scanning %d search paths\n', numel(searchPaths));
    for i = 1:numel(searchPaths)
        fprintf('    %s\n', searchPaths{i});
    end

    rigs = symphonyui.ui.ProtocolScanner.discoverRigs(searchPaths);
    fprintf('csbridge.discoverRigs: found %d rigs\n', numel(rigs));
    items = repmat(struct('className', '', 'displayName', ''), 1, numel(rigs));
    for i = 1:numel(rigs)
        items(i).className = char(rigs(i).id);
        items(i).displayName = char(rigs(i).displayName);
    end
    json = jsonencode(items);
end
