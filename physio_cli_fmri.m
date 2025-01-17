function physio_cli_fmri(use_case, out_dir, correct, varargin)   
%% A command line wrapper for the main entry function 
% The main purpose of this script is integraton to CBRAIN yet it 
% can be used with other frameworks as well, or compilation so tool can be used
% on machine without MATLAB
%
% NOTE: All physio-structure can be specified previous to
%       running this function, e.g model.retroir.c, 3, save_dir - prefix
%       for resulting folder and in_dir are positional parameters, absent 
%        in the original physio.
%
% IN 
%   in_dir           Folder containing input data (logfiles and fMRI data)
%   out_dir          Name of folder for outputs
%   use_case         Specifies what input directory structure to expect
%   correct          Choose whether to correct fMRI run or just produce
%                    regressors
%
% OUT
%   multiple_regressors.txt       File containing regressors generated by
%                                 PhysIO
%   *.png                         Diagnostic plots from PhysIO
%   fmri_corrected.nii            If 'correct' is set to 'yes', returns
%                                 corrected fMRI image
%   pct.var.reduced.nii           3D double representing the pct var
%                                 reduced by the regressors at each voxel
%
% EXAMPLES
%
%   physio_cli_fmri('input_folder',...
%                   'output_folder',...
%                   'Single_run',...
%                   'yes',...
%                   'param_1', 'value_1',...
%                   'param_2', 'value_2',...
%                   'param_3', 'value_3') 
%
%
% TODO:
%
%   Fix figure generation
%   Implement validation and error catching for input folder scanning
%   Add more physio format use cases
%   Allow for unzipped niftis as input
%
%
% REFERENCES
%
% CBRAIN        www.cbrain.com 
% RETROICOR     regressor creation based on Glover et al. 2000, MRM 44 and
%               Josephs et al. 1997, ISMRM 5, p. 1682
%               default model order based on Harvey et al. 2008, JMRI 28
% RVT           (Respiratory volume per time) Birn et al. 2008, NI 40
% HRV           (Heart-rate  variability) regressor creation based on
%               Chang et al2009, NI 44
%
% See also tapas_physio_new

% Author:    Serge Boroday
% Created:   2021-03-16
% Copyright: McGill University
%
% Modified by:  Darius Valevicius
% Date:         2021-06-22
%
% The original tool is by Institute for Biomedical Engineering, 
%               University of Zurich and ETH Zurich.
%
% This file is a wrapper for TAPAS PhysIO Toolbox


%SEPARATOR = '\s*[,\s]'; % the separator for vector/interval inputs - coma and/or white space
%DOT = '__'; % to use MATLAP argument parser the dots are replaced with doubleunderscore

% Diagnostic print output
% disp("PWD and work dir contents:");
% disp(pwd);
% disp(struct2table(dir()));

% Add PhysIO code to path (Does not work with compiler)
% addpath(genpath('code'));

%% Input Parser

p = inputParser;
p.KeepUnmatched = true;


addRequired(p, 'use_case');
%addParameter(p, 'in_dir', 'none');
% Not sure how this will work in tandem with boutiques. Setting all to
% required now, with optional params defaulting to 'none'.
%addRequired(p, 'in_dir');

addRequired(p, 'out_dir');

%addRequired(p, 'fmri_file');
%addParameter(p, 'fmri_file', 'none');

addRequired(p, 'correct');

parse(p, use_case, out_dir, correct);

% Debugging: display inputs

%input_msg = ['Use case: ',use_case,', In dir: ',in_dir,', Out dir: ',out_dir,', Fmri file: ',fmri_file,', Correct: ',correct];

%disp(input_msg);


%% Create default parameter structure with all fields
physio = tapas_physio_new();

physio = setDefaults(physio);

%% Set specified parameters (save_dir and varargin)

varargin(1:2:end) = strrep(varargin(1:2:end), '.', '__'); 
fields = [varargin(1:2:end); varargin(2:2:end)];


% Set params in physio structure from varargin
for i = 1:size(fields, 2)
    
    field_value = fields{2, i};
    
    if (~isnan(str2double(field_value)))
        field_value = str2double(field_value);
    elseif (strcmp(field_value, 'yes') || strcmp(field_value, 'true'))
        field_value = 1;
    elseif (strcmp(field_value, 'no') || strcmp(field_value, 'false'))
        field_value = 0;
    end
    
    fieldseq = regexp(fields{1, i}, '__', 'split');
    physio = setfield(physio, fieldseq{:}, field_value);
end


%% Set fmri_file and in_dir values (hackey workaround to CBRAIN interface problem)
% Problem description: File type inputs in CBRAIN cannot have default
% values. Therefore they can't be passed as positional params, and have to
% be extracted from varargin.

in_dir = 'none';
fmri_file = 'none';

if isfield(physio, 'in_dir')
    in_dir = physio.in_dir;
end
if isfield(physio, 'fmri_file')
    fmri_file = physio.fmri_file;
end

%% Scan subject directory and perform correction on each fMRI file

phys_ext = '';
%cardiac_marker = '';
%resp_marker = '';

switch physio.log_files.vendor
    case 'BIDS'
        phys_ext = '.tsv.gz';
        %n_logfiles = 1;
    case 'Philips'
        phys_ext = '.log';
        %n_logfiles = 1;
    case 'Biopac_Txt'
        phys_ext = '.txt';
        %n_logfiles = 1;
    case 'Biopac_Mat'
        phys_ext = '.mat';
        %n_logfiles = 1;
    case 'BrainProducts'
        phys_ext = '.eeg';
        %n_logfiles = 1;
end

switch use_case
    case 'bids_subject_folder'
        
        % From input/subject folder
        % Get every nifti in func
        % and associated physlogfiles
        % based on vendor
        %   BIDS: .tsv.gz
        %   Philips: .log
        %   
        % Currently implemented for BIDS and Philips only    

        if strcmp(in_dir, 'none')
            msg = 'BIDS scanning use-case requires input directory.';
            error(msg)
        end
        
        
        subject_folder = in_dir;

        % Get first level subdirectory
        
        first_lvl = get_folder_contents(subject_folder);
        
        if ~any(contains(first_lvl, 'ses')) && ~any(contains(first_lvl, 'func'))
            % folder is unexpectedly nested
            % Throw error if >1 folder in top level folder.
            if size(first_lvl, 2) ~= 1
                msg = 'Invalid folder structure. Check BIDS specifications.';
                error(msg)
            end
            
            % Set subject_folder to be two levels deep
            subject_folder = fullfile(in_dir, string(first_lvl));
            
            % Recoup folder contents
            first_lvl = get_folder_contents(subject_folder);
        end
        
            

        % If multiple sessions, use those
        % Else set sessions to 1x1 empty string cell array. This will be ignored in
        % fullfile() calls
        if any(contains(first_lvl, 'ses'))
            sessions = first_lvl;
        elseif any(contains(first_lvl, 'func'))
            sessions = {''};
        end

        disp('Iterating through fMRI files in subject folder.');

        % Iterate through sessions
        for s = sessions

            % Get all files in func directory
            func = get_folder_contents(fullfile(subject_folder, s{:}, 'func'));
            
            % diagnostic: print folder contents
            %disp("In_dir contents:");
            %disp(struct2table(dir(in_dir)));
            %disp("Func contents:");
            %disp(func);

            % Get fMRI files
            fmri_files = func(contains(func, '.nii'));

            if isempty(fmri_files)
                msg = 'Did not find any fMRI files in func directory.';
                error(msg)
            end

            % For every fMRI file
            % Try to find corresponding physio logfile
            % Corresponding to run #
            % Set PhysIO parameters and run PhysIO

            for j = fmri_files

                disp(append('Correcting: ', j{:}))

                % Get file sub/ses/task string

                run_string = extractBefore(j{:}, '_bold');

                % Find logfile

                index = regexp(func, append(run_string, '.*', phys_ext));

                logfile = func(~cellfun(@isempty, index));

                if isempty(logfile)
                    msg = append('Logfile for fMRI run ', j{:}, ' not found.');
                    error(msg);
                end

                % Set PhysIO params

                save_foldername = append(extractBefore(j, '.nii'), '_physio_results');

                % Set fmri param
                fmri_filename = string(fullfile(subject_folder, s, 'func', j));

                % Set save dir and logfile params
                physio.save_dir = fullfile(out_dir, save_foldername);

                logfile = fullfile(in_dir, s, 'func', logfile);
                physio.log_files.cardiac = logfile;
                physio.log_files.respiration = logfile;


                % Refresh some params (they would stack otherwise)
                % NOTE: the fact that this is needed may signal that other
                % parameters may break/stack when physio is looped. Keep an eye out,
                % may need to recode
                physio.model.output_physio = 'physio.mat';
                physio.model.output_multiple_regressors = 'multiple_regressors.txt';

                % Get fMRI dimensions  
                [fmri_j, Nslices, Nframes] = load_fmri(fmri_filename);

                physio.scan_timing.sqpar.Nslices = Nslices;
                physio.scan_timing.sqpar.Nscans = Nframes;

                % physio.verbose.fig_output_file = append(run_string, '_fig_output.jpg');
                
                % Run physio
                physio = run_physio(physio);
                
                % Run image correction
                if(strcmpi(correct, 'yes'))
                    performCorrection(fmri_filename, fmri_j, physio);
                end

            end

        end

    case 'single_run_folder'
        
        if strcmp(in_dir, 'none')
            msg = 'Single-run use-case requires input directory.';
            error(msg)
        end
        
        % Find fMRI file in input folder
        file_inputs = get_folder_contents(in_dir);
        
        
        if ~any(contains(file_inputs, '.nii'))
            % folder is unexpectedly nested
            % Throw error if >1 folder in top level folder.
            if size(file_inputs, 2) ~= 1
                msg = 'Invalid folder structure. Check BIDS specifications.';
                error(msg)
            end
            
            % Set subject_folder to be two levels deep
            in_dir = fullfile(in_dir, string(file_inputs));
            
            % Recoup folder contents
            file_inputs = get_folder_contents(in_dir);
        end
        
        % diagnostic: print folder contents
        %disp("In_dir contents:");
        %disp(struct2table(dir(in_dir)));
        %disp("File_inputs:");
        %disp(file_inputs);

        fmri_filename = string(file_inputs(contains(file_inputs, '.nii')));
        if isempty(fmri_filename)
            msg = 'Did not find any fMRI files in input directory.';
            error(msg);
        elseif numel(fmri_filename) > 1
            msg = 'Too many ( > 1 ) fMRI files in input directory.';
            error(msg);
        end
        % run_string = extractBefore(fmri_filename, '_bold');

        % Find logfile
        logfile = string(file_inputs(contains(file_inputs, phys_ext)));
        if isempty(logfile)
            msg = append('Logfile for fMRI run not found.');
            error(msg);
        end

        % Set PhysIO params

        save_foldername = append(extractBefore(fmri_filename, '.nii'), '_physio_results');

        % Unzip and set fmri param
        fmri_filename = fullfile(in_dir, fmri_filename);

        % Set save dir and logfile params
        physio.save_dir = fullfile(out_dir, save_foldername);

        logfile = fullfile(in_dir, logfile);
        physio.log_files.cardiac = logfile;
        physio.log_files.respiration = logfile;

        % Get fMRI dimensions
        [fmri_data, Nslices, Nframes] = load_fmri(fmri_filename);

        physio.scan_timing.sqpar.Nslices = Nslices;
        physio.scan_timing.sqpar.Nscans = Nframes;

        % physio.verbose.fig_output_file = append(run_string, '_fig_output.jpg');

        % Run physio
        physio = run_physio(physio);

        % Run image correction
        if(strcmpi(correct, 'yes'))
            performCorrection(fmri_filename, fmri_data, physio);
        end
    
    case 'manual_input'
        
        % No fmri input error
        if (strcmp(fmri_file, 'none'))
            msg = 'Manual input: No fMRI file was input.';
            error(msg);
        end
        
        % No logfile input error
        % also handles combined input if individual carfiles are not given
        if (~isfile(physio.log_files.cardiac) && ~isfile(physio.log_files.respiration))
            try 
                isfile(physio.log_files.cardiac_respiration);
                physio.log_files.cardiac = physio.log_files.cardiac_respiration;
                physio.log_files.respiration = physio.log_files.cardiac_respiration;
            catch
                msg = append('Manual input: Log file(s) are invalid. Input at least one logfile.');
                error(msg);
            end
        end
            
        
        physio.save_dir = out_dir;
        
        % Get fMRI dimensions  
        [fmri_data, Nslices, Nframes] = load_fmri(fmri_file);

        physio.scan_timing.sqpar.Nslices = Nslices;
        physio.scan_timing.sqpar.Nscans = Nframes;

        % physio.verbose.fig_output_file = append(fmri_file, '_fig_output.jpg');
        
        % Run physio
        physio = run_physio(physio);
                
        % Run image correction
        if(strcmpi(correct, 'yes'))
            performCorrection(fmri_file, fmri_data, physio);
        end
        
    otherwise
        msg = 'No valid use-case selected.';
        error(msg);
    
end


end

function [contents] = get_folder_contents(folder)
    % gets the names of files in folder, minus . and ..
    
    temp = dir(folder);
    contents = {temp(3:end).name};

end

function [physio] = run_physio(physio)

% postpone figs
disp('Postponing figure generation...');
[physio, verbose_level, fig_output_file] = postpone_figures(physio);
%disp('fig name:');
%disp(fig_output_file);
% Run PhysIO
disp('Creating PhysIO regressors...');
physio = tapas_physio_main_create_regressors(physio);
disp('Complete.');

% generate figures without rendering
disp('Generating and saving figures...');
generate_figures(physio, verbose_level, fig_output_file);
        
end


function [physio, verbose_level, fig_output_file] = postpone_figures(physio)

% postpone figure generation in first run - helps with compilation
% relies on certain physio.verbose parameters - see setDefaults() below
if isfield(physio, 'verbose') && isfield(physio.verbose, 'level')
     verbose_level = physio.verbose.level;
     physio.verbose.level = 0;
     if isfield(physio.verbose, 'fig_output_file') && ~strcmp(physio.verbose.fig_output_file, '')
         fig_output_file = physio.verbose.fig_output_file;
     else
         fig_output_file = 'PhysIO_output.jpg'; 
     end    
else
  verbose_level = 0;
end 

end

function generate_figures(physio, verbose_level, fig_output_file)

% Build figures
if verbose_level
  physio.verbose.fig_output_file = fig_output_file; % has to reset, the old value is distorted
  physio.verbose.level = verbose_level;
  tapas_physio_review(physio);
end

end

function [fmri_data, Nslices, Nframes] = load_fmri(fmri_file)

    try
        fmri_data = double(niftiread(string(fmri_file)));
    catch ME
        warning('Problem reading fMRI file. Please verify that file is uncorrupted and in correct format.');
        disp(string(fmri_file));
        rethrow(ME)
    end
    sz = size(fmri_data);
    Nslices = sz(3);
    Nframes = sz(4);

end

function [S] = merge_struct(S_1, S_2)
% update the first struct with values and keys of the second and returns the result
% deep update, merges substructrues recursively, the values from the first
% coinside

f = fieldnames(S_2);

for i = 1:length(f)
    if isfield(S_1, f{i}) && isstruct(S_1.(f{i})) && isstruct(S_2.(f{i}))
        S_1.(f{i}) = merge_struct(S_1.(f{i}), S_2.(f{i}));
    else   
        S_1.(f{i}) = S_2.(f{i});
    end        
end
S = S_1;
end


function performCorrection(fmri_filename, fmri_data, physio)


disp('Correcting fMRI data...');

disp('Loading regressors...');
% Load multiple regressors file
regressors = load(fullfile(physio.save_dir, 'multiple_regressors.txt'));

disp('Running Correction...');
% Run correction
[fmri_corrected, pct_var_reduced] = correct_fmri(fmri_data, regressors);

disp('Correction complete.');
fprintf('Maximum variance reduced(diagnostic): %d\n', max(pct_var_reduced, [], 'all'));

disp('Getting header info...');
fmri_header = niftiinfo(string(fmri_filename));

disp('Typecasting data...');
data_type = fmri_header.Datatype;
fmri_corrected_typecast = cast(fmri_corrected(:), data_type);
fmri_corrected_typecast = reshape(fmri_corrected_typecast, size(fmri_corrected));

disp('Writing niftis...');
% Create output files
[~,fmri_name_only,ext] = fileparts(fmri_filename);
fmri_name_only = extractBefore(append(fmri_name_only, ext), '.nii');
fmri_corrected_filename = append(fmri_name_only, '_corrected.nii');

niftiwrite(fmri_corrected_typecast, fullfile(physio.save_dir, fmri_corrected_filename), fmri_header);
niftiwrite(pct_var_reduced, fullfile(physio.save_dir, 'pct_var_reduced.nii'));
%gzip(strcat(physio.save_dir, '/fmri_corrected.nii'));

disp('Complete.');


end

function [fmri_corrected, pct_var_reduced] = correct_fmri(fmri_data, regressors)
% Correction algorithm adapted from Catie Chang

disp('Getting dimensions...');
% Get dimensions
x = size(fmri_data);
nslices = x(3);
nframes = x(4);

disp('Arranging label...');
% Arrange data label
Y = reshape(fmri_data, x(1)*x(2)*nslices, nframes)';
t = (1:nframes)';

disp('Setting up design matrix...');
% Set design matrix
% Uses intercept (1), time, time squared, and PhysIO regressors
XX = [t, t.^2, regressors];
XX = [ones(size(XX,1),1), zscore(XX)];

disp('Regressing...');
% Compute model betas and subtract beta-weighted regressors from input fmri
% data to correct
Betas = XX\Y;
Y_corr = Y - XX(:,4:end)*Betas(4:end,:);

disp('Correcting...');
fmri_corrected = reshape(Y_corr', x(1), x(2), nslices, nframes);

disp('Computing pct var reduced...');
% Compute pct var reduced (3D double)
%disp('Get raw fmri variance');
var_raw = var(fmri_data, 0, 4);
%disp('Get corrected fmri variance');
var_corrected = var(fmri_corrected, 0, 4);
%disp('Get difference in variance');
pct_var_reduced = (var_raw - var_corrected) ./ var_raw;

%disp('Creating Mask...')
%mask = createMask(fmri_data);
% niftiwrite(mask, 'mask_test.nii');
%pct_var_reduced = pct_var_reduced .* mask;


end

function [mask] = createMask(fmri_data)
% Quick and dirty whole-brain masking function (not very good)
% Sets to zero all voxels whose average activation is less than 80% of the
% grand mean

disp('Applying mask...')
fmri_avg = mean(fmri_data, 4);
fmri_grand_mean = mean(fmri_avg, 'all');

mask = ones(size(fmri_avg));

mask(fmri_avg < (0.8 * fmri_grand_mean)) = 0;
disp('Complete.')

end


function [physio] = setDefaults(physio)
% PhysIO defaults as specified by PhysIO's 'template_matlab_script.m'
% <UNDEFINED> parameters must have an input!
% with the exception of cardiac and resp logfiles, if they are set not
% to be used

physio.save_dir = {'physio_out'};
physio.log_files.vendor = 'Philips';
physio.log_files.cardiac = '<UNDEFINED>';
physio.log_files.respiration = '<UNDEFINED>';
physio.log_files.relative_start_acquisition = 0;
physio.log_files.align_scan = 'last';
physio.scan_timing.sqpar.Nslices = '<UNDEFINED>';
physio.scan_timing.sqpar.TR = '<UNDEFINED>';
physio.scan_timing.sqpar.Ndummies = '<UNDEFINED>';
physio.scan_timing.sqpar.Nscans = '<UNDEFINED>';
physio.scan_timing.sqpar.onset_slice = '<UNDEFINED>';
physio.scan_timing.sync.method = 'nominal';
physio.preproc.cardiac.modality = 'ECG';
physio.preproc.cardiac.filter.include = false;
physio.preproc.cardiac.filter.type = 'butter';
physio.preproc.cardiac.filter.passband = [0.3 9];
physio.preproc.cardiac.initial_cpulse_select.method = 'auto_matched';
physio.preproc.cardiac.initial_cpulse_select.max_heart_rate_bpm = 90;
physio.preproc.cardiac.initial_cpulse_select.file = 'initial_cpulse_kRpeakfile.mat';
physio.preproc.cardiac.initial_cpulse_select.min = 0.4;
physio.preproc.cardiac.posthoc_cpulse_select.method = 'off';
physio.preproc.cardiac.posthoc_cpulse_select.percentile = 80;
physio.preproc.cardiac.posthoc_cpulse_select.upper_thresh = 60;
physio.preproc.cardiac.posthoc_cpulse_select.lower_thresh = 60;
physio.model.orthogonalise = 'none';
physio.model.censor_unreliable_recording_intervals = false;
physio.model.output_multiple_regressors = 'multiple_regressors.txt';
physio.model.output_physio = 'physio.mat';
physio.model.retroicor.include = true;
physio.model.retroicor.order.c = 3;
physio.model.retroicor.order.r = 4;
physio.model.retroicor.order.cr = 1;
physio.model.rvt.include = false;
physio.model.rvt.delays = 0;
physio.model.hrv.include = false;
physio.model.hrv.delays = 0;
physio.model.noise_rois.include = false;
physio.model.noise_rois.thresholds = 0.9;
physio.model.noise_rois.n_voxel_crop = 0;
physio.model.noise_rois.n_components = 1;
physio.model.noise_rois.force_coregister = 1;
physio.model.movement.include = false;
physio.model.movement.order = 6;
physio.model.movement.censoring_threshold = 0.5;
physio.model.movement.censoring_method = 'FD';
physio.model.other.include = false;
physio.verbose.level = 2;
physio.verbose.process_log = cell(0, 1);
physio.verbose.fig_handles = zeros(1, 0);
physio.verbose.use_tabs = false;
physio.verbose.show_figs = false; % Changed from templates
physio.verbose.save_figs = true; % Changed from template
physio.verbose.close_figs = true; % Changed from template
physio.ons_secs.c_scaling = 1;
physio.ons_secs.r_scaling = 1;

end


