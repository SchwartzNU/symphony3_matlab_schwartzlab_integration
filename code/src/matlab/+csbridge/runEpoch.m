function out = runEpoch(mode)
    %CSBRIDGE.RUNEPOCH  Run a single View-Only epoch on Stage.
    %
    %   csbridge.runEpoch('presentation')
    %       (default if no mode given) — only createPresentation +
    %       videoDevice.play. The simplest path; works for any
    %       protocol whose stimulus is fully described by its
    %       current property values without per-epoch state mutation.
    %       This is the path that's been stable on macOS since the
    %       initial spike.
    %
    %   csbridge.runEpoch('epoch')
    %       prepareEpoch(epoch) + createPresentation + play +
    %       completeEpoch(epoch). Required for vector-sweeping
    %       protocols (e.g. MovingBar over a vector of barAngle
    %       values) where the protocol picks its per-epoch scalar
    %       inside prepareEpoch. Caller is responsible for first
    %       initializing the protocol's prepareRun-managed state if
    %       the protocol depends on it (counters, figures).
    %
    %   Returns '' to satisfy the C# nargout>=1 dispatcher.

    if nargin < 1 || isempty(mode)
        mode = 'presentation';
    end
    out = '';

    s = csbridge.State.instance();
    if isempty(s.rig)
        error('csbridge:noRig', 'No rig is initialized.');
    end
    if isempty(s.protocol)
        error('csbridge:noProtocol', 'No protocol is selected.');
    end

    videoDevice = findVideoDevice(s.rig);
    if isempty(videoDevice)
        error('csbridge:noVideoDevice', ...
            'No VideoDevice found in the current rig.');
    end

    epoch = [];
    if strcmpi(mode, 'epoch')
        % Allocate a ViewOnlyEpoch — a subclass of the real Epoch
        % that no-ops every DAQ-touching method (addStimulus,
        % addResponse, addDirectCurrentStimulus, setBackground).
        % This lets the protocol's prepareEpoch run to completion —
        % vector parameters get rolled, per-epoch state advances —
        % without firing the DirectCurrent stimulus generator or
        % attaching response sinks. We're playing visual stimuli on
        % Stage; the DAQ pipeline isn't involved.
        epoch = csbridge.ViewOnlyEpoch();
        s.protocol.prepareEpoch(epoch);
    end

    presentation = s.protocol.createPresentation();
    if isempty(presentation) || ~isa(presentation, 'stage.core.Presentation')
        error('csbridge:badPresentation', ...
            'Protocol "%s" did not return a stage.core.Presentation.', ...
            class(s.protocol));
    end

    videoDevice.play(presentation);

    if strcmpi(mode, 'epoch') && ~isempty(epoch)
        % completeEpoch base implementation bumps a counter and
        % updates figure handlers (no-op when none are registered).
        % We swallow MException here so a transient figure handler
        % issue doesn't abort the whole run.
        try
            s.protocol.completeEpoch(epoch);
        catch err
            warning('csbridge:completeEpoch', ...
                'completeEpoch threw (continuing): %s', err.message);
        end
    end
end


function vd = findVideoDevice(rig)
    vd = [];
    for i = 1:numel(rig.devices)
        d = rig.devices{i};
        try, n = char(d.name); catch, continue; end
        if startsWith(n, 'SimulatedStage.Stage@') ...
                || endsWith(n, 'Stage') ...
                || contains(n, '.Stage@')
            vd = d;
            return;
        end
    end
end
