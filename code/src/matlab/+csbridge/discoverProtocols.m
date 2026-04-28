function json = discoverProtocols(searchPaths)
    %CSBRIDGE.DISCOVERPROTOCOLS  Return JSON list of available protocols.
    %
    %   json = csbridge.discoverProtocols()
    %   json = csbridge.discoverProtocols({'/path/with/+protocols'})
    %
    %   Output: [{"className":"common.protocols.SingleSpot","displayName":"Single Spot"}, ...]

    if nargin < 1 || isempty(searchPaths)
        searchPaths = csbridge.getSearchPaths();
    end
    fprintf('csbridge.discoverProtocols: scanning %d search paths\n', numel(searchPaths));

    protocols = symphonyui.ui.ProtocolScanner.discover(searchPaths);
    fprintf('csbridge.discoverProtocols: found %d protocols\n', numel(protocols));
    items = repmat(struct('className', '', 'displayName', ''), 1, numel(protocols));
    for i = 1:numel(protocols)
        items(i).className = char(protocols(i).id);
        items(i).displayName = char(protocols(i).displayName);
    end
    json = jsonencode(items);
end
