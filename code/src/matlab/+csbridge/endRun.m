function out = endRun()
    %CSBRIDGE.ENDRUN  Bookend a View-Only run by calling protocol.completeRun().
    %
    %   Pair with csbridge.beginRun(). Call from a finally block in
    %   the C# loop so completeRun() always fires — including when
    %   the user cancels mid-run via the Stop button.
    %
    %   No-op if no protocol is selected, so it's safe to call
    %   defensively even when beginRun() was skipped.
    %
    %   Returns '' to satisfy the C# nargout>=1 dispatcher.

    out = '';

    s = csbridge.State.instance();
    if isempty(s.protocol)
        return;
    end
    s.protocol.completeRun();
end
