function out = selectProtocol(protocolClassName)
    %CSBRIDGE.SELECTPROTOCOL  Instantiate a protocol and bind it to the rig.
    %   Returns '' to satisfy the C# nargout>=1 dispatcher.

    out = '';
    %
    %   csbridge.selectProtocol('common.protocols.SingleSpot')
    %
    %   Closes the previous protocol if any. Constructs an instance of
    %   the named class, calls setRig() with the current rig (if a rig
    %   has been initialized), and stores the protocol on the State.

    s = csbridge.State.instance();

    if ~isempty(s.protocol)
        try s.protocol.close(); catch, end
    end

    ctorFcn = str2func(protocolClassName);
    s.protocol = ctorFcn();

    if ~isempty(s.rig)
        s.protocol.setRig(s.rig);
    end
end
