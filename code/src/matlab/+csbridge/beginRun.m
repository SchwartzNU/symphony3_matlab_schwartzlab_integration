function out = beginRun()
    %CSBRIDGE.BEGINRUN  Bookend a View-Only run by calling protocol.prepareRun().
    %
    %   Call once before the first csbridge.runEpoch() in a run. Pair
    %   with csbridge.endRun() in a finally block so completeRun()
    %   fires even if the run is cancelled mid-loop.
    %
    %   prepareRun() typically:
    %     - clears any open figure handlers
    %     - resets per-run counters (numEpochsPrepared etc.)
    %     - sets the rig's sample rate from the protocol
    %
    %   Returns '' to satisfy the C# nargout>=1 dispatcher.

    out = '';

    s = csbridge.State.instance();
    if isempty(s.protocol)
        error('csbridge:noProtocol', 'No protocol is selected.');
    end
    s.protocol.prepareRun();
end
