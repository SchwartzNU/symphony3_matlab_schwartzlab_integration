classdef ViewOnlyEpoch < symphonyui.core.Epoch
    %CSBRIDGE.VIEWONLYEPOCH  Epoch stand-in for the C# UI's View-Only loop.
    %
    % On the Mac UI we only care about pushing a visual stimulus to
    % Stage. We don't have (or want) the DAQ pipeline: no amp output,
    % no response capture, no DirectCurrentGenerator-built OutputData.
    %
    % But protocols' prepareEpoch is where they roll their per-epoch
    % state — e.g. MovingBar picks the next barAngle from its sweep
    % vector inside prepareEpoch. We need that to run so
    % createPresentation sees a scalar value.
    %
    % CommonProtocol.prepareEpoch unconditionally calls
    % addAmpResponsesToEpoch(epoch), which calls
    % epoch.addDirectCurrentStimulus(...) for every amp device. That
    % path constructs a DirectCurrentGenerator → OutputData →
    % IOData, which crashes deep in System.Decimal arithmetic on the
    % MATLAB-side stubs. None of it matters for visual stimulus
    % preview.
    %
    % This subclass keeps Epoch's ctor (so .cobj is a valid
    % Symphony.Core.Epoch) and the parameter/property/keyword
    % methods (cheap, useful for record-keeping), but NO-OPs every
    % method that would attach a stimulus / response / background.
    % The protocol thinks it's adding things; nothing actually
    % reaches the DAQ pipeline.

    methods

        function obj = ViewOnlyEpoch(identifier)
            if nargin < 1 || isempty(identifier)
                identifier = sprintf('viewOnly_%s', ...
                    datestr(now, 'yyyymmdd_HHMMSSFFF'));
            end
            obj@symphonyui.core.Epoch(identifier);
        end

        % --- DAQ-touching surface: silenced ----------------------

        function addStimulus(~, ~, ~) %#ok<INUSD>
            % no-op (view-only — no DAQ output)
        end

        function removeStimulus(~, ~) %#ok<INUSD>
            % no-op
        end

        function addDirectCurrentStimulus(~, ~, ~, ~, ~) %#ok<INUSD>
            % no-op — this method's DirectCurrentGenerator call is
            % what was crashing on `Decimal /` in IOData.m.
        end

        function addResponse(~, ~) %#ok<INUSD>
            % no-op (view-only — no DAQ input)
        end

        function removeResponse(~, ~) %#ok<INUSD>
            % no-op
        end

        function setBackground(~, ~, ~) %#ok<INUSD>
            % no-op — also touches device.cobj.OutputSampleRate, a
            % .NET property whose access has SEGV'd on Mac R2024b.
        end

        % --- Predicate methods: report empty ---------------------

        function tf = hasStimulus(~, ~) %#ok<INUSD>
            tf = false;
        end

        function tf = hasResponse(~, ~) %#ok<INUSD>
            tf = false;
        end

        function tf = hasBackground(~, ~) %#ok<INUSD>
            tf = false;
        end

        % --- Accessor methods: error so misuse is loud -----------

        function s = getStimulus(~, ~) %#ok<INUSD>
            error('csbridge:viewOnlyEpoch:noStimuli', ...
                'getStimulus is not supported on a ViewOnlyEpoch.');
        end

        function r = getResponse(~, ~) %#ok<INUSD>
            error('csbridge:viewOnlyEpoch:noResponses', ...
                'getResponse is not supported on a ViewOnlyEpoch.');
        end

        % addParameter / addProperty / addKeyword from the base
        % class are inherited as-is — they're cheap record-keeping
        % calls into the .NET Epoch's parameter dictionaries, no
        % DAQ involvement, no Decimal arithmetic, safe to leave on.

    end

end
