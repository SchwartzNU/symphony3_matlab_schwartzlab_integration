% clear classes;
%clear all; rehash toolboxcache;

%rehash;
%rehash;

% Force ITCMM.dll to load via the C++/CLI bridge path (implicit DLL loading)
%try
%    NET.addAssembly(fullfile(pwd, 'code', 'core', 'win_x64', 'HekaIOBridge.dll'));
%    disp('HekaIOBridge loaded — ITCMM.dll should now be implicitly loaded');
%catch e
%    disp(e.message);
%end


app = SymphonyApp();

