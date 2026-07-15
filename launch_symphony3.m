function launch_symphony3()
%LAUNCH_SYMPHONY3  Start the Symphony 3 port from its dedicated checkouts.
%
%   Run this in your NEWER MATLAB (e.g. R2025a). Symphony 1 stays in R2018b and
%   is launched the way you do today; because the two use different MATLAB
%   installs, their paths can never bleed into each other.
%
%   Save this file in the folder named by 'bootstrapDir' below (the same folder
%   that holds bootstrap_sa_labs.m), and just run  launch_symphony3  at the
%   R2025a prompt.
%
%   Edit the paths below if your folders differ.

    % ---- edit these to match your machine --------------------------------
    fork         = 'D:\Code\symphony3_matlab_schwartzlab_integration';
    ext          = 'D:\Code\sa-labs-extension-s3';   % the symphony3-port checkout
    stage        = 'D:\Code\stage3_testbed';         % only needed for visual protocols
    bootstrapDir = 'D:\Code';                        % folder containing bootstrap_sa_labs.m
    % ----------------------------------------------------------------------

    assert(isfolder(fork), 'Fork not found: %s', fork);
    assert(isfolder(ext),  'Extension (-s3) not found: %s', ext);

    % Start from a clean path so nothing already installed (for example a GUI
    % Layout Toolbox Add-On) can shadow the fork's vendored uix. This session is
    % dedicated to Symphony 3, so a clean path is exactly what we want.
    restoredefaultpath;
    rehash toolboxcache;

    % Make bootstrap_sa_labs visible, then let it wire up everything. Passing
    % fork/ext/stage explicitly means the bootstrap does NOT rely on its folders
    % sharing a parent, so it always uses the -s3 checkout.
    addpath(bootstrapDir);
    bootstrap_sa_labs('fork', fork, 'ext', ext, 'stage', stage, 'launch', true);

    % Confirm the Symphony 3 extension copy is the one actually on the path.
    fprintf('\nBackgroundControl resolves to:\n  %s\n', ...
        which('sa_labs.modules.BackgroundControl'));
end