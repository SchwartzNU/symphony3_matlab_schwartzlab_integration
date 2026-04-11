classdef StreamingEpochReader < handle
    % Reads streaming epoch data from HDF5 files.
    %
    % Streaming epochs use chunked, extendable datasets that are written
    % incrementally during acquisition. This reader handles both the new
    % streaming format (streamingVersion >= 2) and the legacy format.
    %
    % Usage:
    %   reader = StreamingEpochReader('experiment.h5');
    %   epochs = reader.getEpochPaths();
    %   data = reader.readResponse(epochs{1}, 'Amp1');
    %   info = reader.readEpochInfo(epochs{1});
    %   reader.close();
    
    properties (Access = private)
        filepath
    end
    
    methods
        
        function obj = StreamingEpochReader(filepath)
            obj.filepath = filepath;
        end
        
        function paths = getEpochPaths(obj)
            % Returns cell array of epoch group paths in the file.
            % Streaming epochs live under /streaming/epoch-{uuid}
            paths = {};
            try
                info = h5info(obj.filepath, '/streaming');
                for i = 1:numel(info.Groups)
                    name = info.Groups(i).Name;
                    if contains(name, 'epoch-')
                        paths{end+1} = name; %#ok<AGROW>
                    end
                end
            catch
                % No /streaming group — no streaming epochs in this file
            end
        end
        
        function info = readEpochInfo(obj, epochPath)
            % Reads epoch metadata (protocol, timing, partial flag).
            info = struct();
            info.protocolID = h5readatt(obj.filepath, epochPath, 'protocolID');
            info.startTime = h5readatt(obj.filepath, epochPath, 'startTime');
            
            try
                info.endTime = h5readatt(obj.filepath, epochPath, 'endTime');
            catch
                info.endTime = ''; % not yet finalized
            end
            
            try
                info.isPartial = h5readatt(obj.filepath, epochPath, 'isPartial') > 0;
            catch
                info.isPartial = true; % missing = crashed before finalization
            end
            
            try
                info.streamingVersion = h5readatt(obj.filepath, epochPath, 'streamingVersion');
            catch
                info.streamingVersion = 1; % legacy format
            end
        end
        
        function data = readResponse(obj, epochPath, deviceName)
            % Reads response data for a device.
            %   data = reader.readResponse('/epoch-abc123', 'Amp1');
            %   data.values     - double array of samples
            %   data.sampleRate - sample rate in Hz
            %   data.units      - measurement units
            %   data.inputTime  - ISO 8601 timestamp
            
            datasetPath = [epochPath '/responses/' deviceName];
            data = struct();
            data.values = h5read(obj.filepath, datasetPath);
            data.sampleRate = h5readatt(obj.filepath, datasetPath, 'sampleRate');
            data.units = h5readatt(obj.filepath, datasetPath, 'units');
            
            try
                data.inputTime = h5readatt(obj.filepath, datasetPath, 'inputTime');
            catch
                data.inputTime = '';
            end
        end
        
        function data = readStimulus(obj, epochPath, deviceName)
            % Reads stimulus data for a device.
            datasetPath = [epochPath '/stimuli/' deviceName];
            data = struct();
            data.values = h5read(obj.filepath, datasetPath);
            data.sampleRate = h5readatt(obj.filepath, datasetPath, 'sampleRate');
            data.units = h5readatt(obj.filepath, datasetPath, 'units');
            data.stimulusID = h5readatt(obj.filepath, datasetPath, 'stimulusID');
        end
        
        function bg = readBackground(obj, epochPath, deviceName)
            % Reads background info for a device.
            groupPath = [epochPath '/backgrounds/' deviceName];
            bg = struct();
            bg.value = h5readatt(obj.filepath, groupPath, 'value');
            bg.units = h5readatt(obj.filepath, groupPath, 'units');
            bg.sampleRate = h5readatt(obj.filepath, groupPath, 'sampleRate');
        end
        
        function params = readProtocolParameters(obj, epochPath)
            % Reads protocol parameters as a struct.
            groupPath = [epochPath '/protocolParameters'];
            info = h5info(obj.filepath, groupPath);
            params = struct();
            for i = 1:numel(info.Attributes)
                name = info.Attributes(i).Name;
                value = h5readatt(obj.filepath, groupPath, name);
                params.(matlab.lang.makeValidName(name)) = value;
            end
        end
        
        function devices = getResponseDevices(obj, epochPath)
            % Returns cell array of device names that have responses.
            groupPath = [epochPath '/responses'];
            try
                info = h5info(obj.filepath, groupPath);
                devices = cell(1, numel(info.Datasets));
                for i = 1:numel(info.Datasets)
                    devices{i} = info.Datasets(i).Name;
                end
            catch
                devices = {};
            end
        end
        
        function n = getResponseSampleCount(obj, epochPath, deviceName)
            % Returns the number of samples in a response dataset.
            datasetPath = [epochPath '/responses/' deviceName];
            info = h5info(obj.filepath, datasetPath);
            n = info.Dataspace.Size;
        end
        
        function close(obj)
            % No-op for MATLAB h5read (file is not held open).
        end
        
    end
    
    methods (Static)
        
        function recoverCrashedEpochs(filepath)
            % Scans for streaming epochs that weren't finalized (crashed mid-recording)
            % and marks them as partial.
            %
            % Usage:
            %   StreamingEpochReader.recoverCrashedEpochs('experiment.h5');
            
            reader = StreamingEpochReader(filepath);
            paths = reader.getEpochPaths();
            
            recovered = 0;
            for i = 1:numel(paths)
                info = reader.readEpochInfo(paths{i});
                if isempty(info.endTime)
                    fprintf('Recovering crashed epoch: %s\n', paths{i});
                    h5writeatt(filepath, paths{i}, 'endTime', char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSSSSSSxxx')));
                    h5writeatt(filepath, paths{i}, 'isPartial', uint32(1));
                    recovered = recovered + 1;
                end
            end
            
            if recovered == 0
                fprintf('No crashed epochs found.\n');
            else
                fprintf('Recovered %d crashed epoch(s).\n', recovered);
            end
            
            reader.close();
        end
        
    end
    
end
