function json = getRunInfo()
    %CSBRIDGE.GETRUNINFO  Return JSON {numberOfAverages, interpulseInterval}.
    %
    %   The C# UI uses this to decide how many epochs to run and
    %   whether to pause between them. Both values fall back to
    %   protocol-friendly defaults when the protocol doesn't declare
    %   the corresponding property.

    s = csbridge.State.instance();

    info = struct();
    info.numberOfAverages = 1;
    info.interpulseInterval = 0;

    if isempty(s.protocol)
        json = jsonencode(info);
        return;
    end

    if isprop(s.protocol, 'numberOfAverages')
        try
            n = double(s.protocol.numberOfAverages);
            if isfinite(n) && n >= 1
                info.numberOfAverages = n;
            end
        catch
        end
    end
    if isprop(s.protocol, 'interpulseInterval')
        try
            d = double(s.protocol.interpulseInterval);
            if isfinite(d) && d >= 0
                info.interpulseInterval = d;
            end
        catch
        end
    end

    json = jsonencode(info);
end
