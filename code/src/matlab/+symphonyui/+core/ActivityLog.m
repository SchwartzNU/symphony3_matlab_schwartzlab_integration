classdef ActivityLog
    % ACTIVITYLOG  Breadcrumbs of what the MATLAB thread is doing during a run.
    %
    %   symphonyui.core.ActivityLog.mark('prepareEpoch %d start', n)
    %
    %   One timestamped line per step in ~/.symphony/logs/activity.log (rotated
    %   at 4 MB to activity.log.1). When Symphony stops responding, the last
    %   line says which step never finished (2026-10-20: a MultiPulse run froze
    %   after 30 epochs with no trace of where). Cheap: one append per step.

    methods (Static)

        function mark(varargin)
            try
                f = symphonyui.core.ActivityLog.file();
                fid = fopen(f, 'a');
                if fid < 0, return; end
                fprintf(fid, '%s | %s\n', datestr(now, 'yyyy-mm-dd HH:MM:SS.FFF'), sprintf(varargin{:}));
                fclose(fid);
                symphonyui.core.ActivityLog.rotateIfLarge(f);
            catch
            end
        end

        function f = file()
            persistent cached
            if isempty(cached)
                d = fullfile(char(java.lang.System.getProperty('user.home')), '.symphony', 'logs');
                if ~isfolder(d)
                    try, mkdir(d); catch, end
                end
                cached = fullfile(d, 'activity.log');
            end
            f = cached;
        end

        function rotateIfLarge(f)
            persistent calls
            if isempty(calls), calls = 0; end
            calls = calls + 1;
            if mod(calls, 200) ~= 0, return; end
            try
                s = dir(f);
                if ~isempty(s) && s.bytes > 4e6
                    movefile(f, [f '.1'], 'f');
                end
            catch
            end
        end
    end
end
