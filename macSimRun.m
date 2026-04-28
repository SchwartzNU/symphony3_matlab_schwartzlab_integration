function rig = macSimRun(stimulusKind, existingRig)
    %MACSIMRUN  Programmatic Symphony->Stage harness for macOS simulation.
    %
    % Built-in stimuli (no protocol class needed):
    %   rig = macSimRun()                       % default: 'rectangle'
    %   rig = macSimRun('rectangle')
    %   rig = macSimRun('spot')
    %   rig = macSimRun('rig-only')             % build rig, no Stage play
    %
    % Symphony Protocol class — pass a fully-qualified class name. The
    % protocol must inherit from a Stage-aware Symphony Protocol base
    % class and implement createPresentation():
    %   rig = macSimRun('common.protocols.SingleSpot')
    %   rig = macSimRun('io.github.stage_vss.protocols.SingleSpot')
    %
    % To run multiple stimuli in one MATLAB session, *reuse the rig* —
    % the VideoDevice's StageClient connection lives on the rig, and
    % rebuilding the rig while the old one's connection is still open
    % can hang Stage. Reuse pattern:
    %
    %   rig = macSimRun('rectangle');           % builds rig, plays
    %   rig = macSimRun('spot', rig);           % reuses rig, plays
    %   rig = macSimRun('common.protocols.SingleSpot', rig);
    %
    %   rig.close();                            % when done — disconnects Stage
    %   clear rig;
    %
    % Symphony's full UI flow (InitializeRigDialog -> Controller ->
    % protocol -> Stage) crashes on macOS R2024b because the MATLAB
    % <-> .NET Core bridge mishandles deferred UI callbacks that touch
    % .NET-backed MCOS properties. This script reproduces the *useful*
    % part of that pipeline without the broken UI:
    %
    %   1. Build the SimulationTest rig description (or reuse one)
    %   2. Wrap it in symphonyui.core.Rig (Mac-safe via MatlabInterop)
    %   3. Pull the VideoDevice out of the rig
    %   4. For protocol-class input: construct + setRig + createPresentation
    %      For built-in stimuli: hand-build a Presentation
    %   5. Push it via videoDevice.play(...) — same code path Symphony
    %      protocols use to render to Stage during acquisition
    %
    % Use this on Mac to verify Symphony->Stage rendering and to drive
    % protocol-level Stage logic from a script. On Windows the full
    % UI flow is unaffected and remains the recommended way to acquire.

    if nargin < 1
        stimulusKind = 'rectangle';
    end

    if nargin >= 2 && ~isempty(existingRig) && isvalid(existingRig) && ~existingRig.isClosed
        rig = existingRig;
        fprintf('macSimRun: reusing existing rig (%d devices)\n', numel(rig.devices));
    else
        fprintf('macSimRun: building rig...\n');
        description = common.rigs.SimulationTest();
        rig = symphonyui.core.Rig(description);
        fprintf('macSimRun: rig built (%d devices)\n', numel(rig.devices));
    end

    if strcmpi(stimulusKind, 'rig-only')
        return;
    end

    % Locate the VideoDevice. SimulationTest names it
    % 'SimulatedStage.Stage@<host>' so we match by prefix.
    videoDevice = [];
    for i = 1:numel(rig.devices)
        d = rig.devices{i};
        try
            n = char(d.name);
        catch
            continue;
        end
        if startsWith(n, 'SimulatedStage.Stage@')
            videoDevice = d;
            break;
        end
    end
    if isempty(videoDevice)
        error('macSimRun:noVideoDevice', ...
              'No VideoDevice found in rig — check SimulationTest.m');
    end
    fprintf('macSimRun: VideoDevice = %s\n', char(videoDevice.name));

    canvasSize = videoDevice.getCanvasSize();
    fprintf('macSimRun: canvas size = [%d %d]\n', canvasSize(1), canvasSize(2));

    if isProtocolClassName(stimulusKind)
        presentation = presentationFromProtocol(stimulusKind, rig);
    else
        presentation = buildPresentation(stimulusKind, canvasSize);
    end

    fprintf('macSimRun: playing %s presentation...\n', stimulusKind);
    videoDevice.play(presentation);
    fprintf('macSimRun: play returned\n');
end


function tf = isProtocolClassName(s)
    % A "Symphony Protocol class name" is any string that contains a
    % dot — built-in stimulus kinds ('rectangle', 'spot', 'rig-only')
    % don't contain dots, fully-qualified MATLAB class names always do.
    tf = contains(s, '.');
end


function p = presentationFromProtocol(className, rig)
    % Construct the protocol, give it the rig, and call its
    % createPresentation() method. The returned object is a
    % stage.core.Presentation, ready to play.
    fprintf('macSimRun: constructing protocol %s\n', className);
    constructor = str2func(className);
    protocol = constructor();

    % Protocol.setRig() triggers didSetRig() in the user's protocol,
    % which typically reads rig.sampleRate and registers device-name
    % properties. Our Mac-safe Rig.get.sampleRate handles this via
    % MatlabInterop primitives.
    protocol.setRig(rig);
    fprintf('macSimRun: protocol.setRig OK; calling createPresentation\n');

    % Stage protocols return a stage.core.Presentation from
    % createPresentation(). If the user's protocol has additional
    % required setup (e.g. selecting an amplifier device by name),
    % they should set that property before calling macSimRun, or
    % subclass the protocol with defaults.
    p = protocol.createPresentation();
    if isempty(p) || ~isa(p, 'stage.core.Presentation')
        error('macSimRun:badProtocol', ...
              ['Protocol "%s" did not return a stage.core.Presentation ', ...
               'from createPresentation()'], className);
    end
end


function p = buildPresentation(kind, canvasSize)
    switch lower(kind)
        case 'rectangle'
            % Solid bright rectangle on a black background, 1 second.
            p = stage.core.Presentation(1.0);
            p.setBackgroundColor(0);

            rect = stage.builtin.stimuli.Rectangle();
            rect.size = [canvasSize(1)/3, canvasSize(2)/3];
            rect.position = canvasSize / 2;
            rect.color = 1.0;
            p.addStimulus(rect);

        case 'spot'
            % Expanding circular spot — exercises Stage's Ellipse stimulus
            % and a per-frame controller. Mirrors the inner loop most
            % Stage protocols use.
            p = stage.core.Presentation(2.0);
            p.setBackgroundColor(0);

            spot = stage.builtin.stimuli.Ellipse();
            spot.position = canvasSize / 2;
            spot.color = 1.0;
            spot.radiusX = 50;
            spot.radiusY = 50;
            p.addStimulus(spot);

            radiusController = stage.builtin.controllers.PropertyController( ...
                spot, 'radiusX', @(s) 50 + 100 * s.time);
            p.addController(radiusController);
            radiusController2 = stage.builtin.controllers.PropertyController( ...
                spot, 'radiusY', @(s) 50 + 100 * s.time);
            p.addController(radiusController2);

        otherwise
            error('macSimRun:unknownStimulus', ...
                  'Unknown stimulusKind "%s" (try ''rectangle'', ''spot'', or ''rig-only'')', kind);
    end
end
