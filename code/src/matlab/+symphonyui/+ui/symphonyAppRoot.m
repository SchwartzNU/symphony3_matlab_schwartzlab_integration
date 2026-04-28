function root = symphonyAppRoot()
    %SYMPHONYAPPROOT  Return the SymphonyApp project root directory.
    %   From +symphonyui/+ui/symphonyAppRoot.m, go up 6 levels:
    %     symphonyAppRoot.m -> +ui -> +symphonyui -> matlab -> src -> code -> SymphonyApp
    p = mfilename('fullpath');
    for k = 1:6
        p = fileparts(p);
    end
    root = p;
end
