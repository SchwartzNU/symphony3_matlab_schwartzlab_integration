function out = initializeRig(rigClassName)
    %CSBRIDGE.INITIALIZERIG  Construct a Rig and store it in the bridge state.
    %
    %   Returns '' so the C# dynamic dispatcher (which always
    %   requests nargout>=1) is satisfied.

    out = '';

    fprintf('csbridge.initializeRig: rigClassName="%s" (class=%s)\n', ...
        char(rigClassName), class(rigClassName));

    s = csbridge.State.instance();

    if ~isempty(s.rig)
        try s.rig.close(); catch, end
        s.rig = [];
    end

    rigClassName = char(rigClassName);  % MATLAB Engine may pass System.String → MATLAB string
    ctorFcn = str2func(rigClassName);
    fprintf('  constructing description %s ...\n', rigClassName);
    description = ctorFcn();
    fprintf('  description constructed (%d devices)\n', numel(description.devices));
    fprintf('  wrapping in Rig...\n');
    s.rig = symphonyui.core.Rig(description);
    fprintf('  rig OK\n');

    if ~isempty(s.protocol)
        fprintf('  re-binding existing protocol to new rig\n');
        s.protocol.setRig(s.rig);
    end
end
