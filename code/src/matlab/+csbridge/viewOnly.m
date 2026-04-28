function out = viewOnly()
    %CSBRIDGE.VIEWONLY  Run all epochs of the current protocol.
    %
    %   Convenience entry-point that loops the protocol's
    %   number-of-averages count and delegates each epoch to
    %   csbridge.runEpoch. Suitable for non-UI scripts that want a
    %   single MATLAB call. The C# UI uses csbridge.runEpoch
    %   directly in a C#-side loop so it can support cancellation.
    %   Returns '' to satisfy the C# nargout>=1 dispatcher.

    out = '';

    s = csbridge.State.instance();
    if isempty(s.protocol)
        error('csbridge:noProtocol', 'No protocol is selected.');
    end

    info = jsondecode(csbridge.getRunInfo());
    nEpochs = info.numberOfAverages;
    intervalSec = info.interpulseInterval;

    for ep = 1:nEpochs
        csbridge.runEpoch();
        if intervalSec > 0 && ep < nEpochs
            pause(intervalSec);
        end
    end
end
