function warmupSymphonyCoreTypes()
    % Force MATLAB's .NET Core lazy type resolution to register every
    % Symphony.Core type used elsewhere in the codebase. Without this,
    % MATLAB on macOS / Linux fails to resolve `Symphony.Core.X(...)`
    % constructor calls until X has been mentioned somewhere — usually
    % via metaclass query (?X) or reflection.
    %
    % This is a no-op on Windows where .NET Framework registers all
    % types eagerly when the assembly loads.

    if ispc
        return;
    end

    types = { ...
        'Controller', ...
        'DAQInputStream', 'DAQOutputStream', ...
        'Measurement', 'Background', ...
        'Epoch', 'EpochGroup', 'EpochBlock', ...
        'OutputData', 'InputData', ...
        'Stimulus', 'Response', 'Device', ...
        'TimeStampedEventArgs', 'TimeStampedEpochEventArgs'};

    for i = 1:numel(types)
        try
            % `?` is a meta-class query; doesn't construct anything,
            % just forces MATLAB to look the type up in loaded
            % assemblies — which registers it for subsequent dotted-
            % name access.
            eval(['?Symphony.Core.' types{i} ';']);
        catch ex
            fprintf(2, 'warmupSymphonyCoreTypes: %s — %s\n', types{i}, ex.message);
        end
    end
end