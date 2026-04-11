classdef SymphonyLegacyContext < handle
    %SYMPHONYLEGACYCONTEXT  MATLAB services stack (same wiring as SymphonyConductor).
    %   Used by SymphonyApp to run DataManagerPresenter + DataManagerView against real HDF
    %   DocumentationService / AcquisitionService / ConfigurationService.

    properties
        session
        documentationService
        acquisitionService
        configurationService
        moduleService
    end

    methods
        function obj = SymphonyLegacyContext(appRoot)
            import symphonyui.app.*;
            import symphonyui.infra.*;

            if nargin < 1 || isempty(appRoot)
                appRoot = symphonyui.ui.symphonyAppRoot();
            end

            coreDir = fullfile(appRoot, 'symphony-core');
            netCore = fullfile(coreDir, 'Symphony.Core', 'bin', 'Debug', 'net10.0', 'Symphony.Core.dll');
            if isfile(netCore)
                NET.addAssembly(netCore);
            end
            % If Acquisition was loaded earlier in the session, "Symphony.Core" dot-syntax can break;
            % use invokeStaticMethod with the full type name.

            options = Options.getDefault();
            exPath = fullfile(appRoot, 'code', 'src', 'resources', 'examples');
            if isfolder(exPath)
                options.searchPath = exPath;
            end

            presets = Presets.getDefault();
            session = Session(options, presets);
            persistorFactory = PersistorFactory();
            classRepository = ClassRepository(options.searchPath, options.searchPathExclude);

            obj.session = session;
            obj.documentationService = DocumentationService(session, persistorFactory, classRepository);
            obj.acquisitionService = AcquisitionService(session, classRepository);
            obj.configurationService = ConfigurationService(session, classRepository);
            obj.moduleService = ModuleService(session, classRepository, obj.documentationService, obj.acquisitionService, obj.configurationService);

            try
                NET.invokeStaticMethod('Symphony.Core.Logging', 'ConfigureLogging', ...
                    char(options.loggingConfigurationFile()), ...
                    char(options.loggingLogDirectory()));
            catch
            end
        end

        function delete(obj)
            try
                if ~isempty(obj.session)
                    obj.session.close();
                end
            catch
            end
        end
    end
end
