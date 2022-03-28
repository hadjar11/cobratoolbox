function [reconVersion,refinedFolder,translatedDraftsFolder,summaryFolder] = runPipeline(draftFolder, varargin)
% This function runs the semi-automatic refinement pipeline consisting of
% three steps: 1) refining all draft reconstructions, 2) testing the
% refined reconstructions against the input data, 3) preparing a report
% detailing any additional debugging that needs to be performed.
%
% USAGE:
%
%    [refinedFolder,translatedDraftsFolder,summaryFolder,sbmlFolder] = runPipeline(draftFolder, varargin)
%
% REQUIRED INPUTS
% draftFolder              Folder with draft COBRA models generated by
%                          KBase pipeline to analyze
% OPTIONAL INPUTS
% translateModels          Boolean indicating whether to translate models
%                          if they are in KBase nomenclature (default: true)
% refinedFolder            Folder with refined COBRA models generated by
%                          the refinement pipeline
% translatedDraftsFolder   Folder with draft COBRA models with translated
%                          nomenclature and stored as mat files
% infoFilePath             File with information on reconstructions to refine
% inputDataFolder          Folder with experimental data and database files
%                          to load
% summaryFolder            Folder with information on performed gapfilling
%                          and refinement
% reconVersion             Name of the refined reconstruction resource
%                          (default: "Reconstructions")
% numWorkers               Number of workers in parallel pool (default: 2)
% createSBML               Defines whether refined reconstructions should
%                          be exported in SBML format (default: false)
%
% OUTPUTS
% reconVersion             Name of the refined reconstruction resource
%                          (default: "Reconstructions")
% refinedFolder            Folder with refined COBRA models generated by
%                          the refinement pipeline
% translatedDraftsFolder   Folder with draft COBRA models with translated
%                          nomenclature and stored as mat files
% summaryFolder            Folder with information on performed gapfilling
%                          and refinement
%
% .. Authors:
%       - Almut Heinken, 06/2020

% Define default input parameters if not specified
parser = inputParser();
parser.addRequired('draftFolder', @ischar);
parser.addParameter('translateModels', true, @islogical);
parser.addParameter('refinedFolder', [pwd filesep 'refinedReconstructions'], @ischar);
parser.addParameter('translatedDraftsFolder', [pwd filesep 'translatedDraftReconstructions'], @ischar);
parser.addParameter('summaryFolder', [pwd filesep 'refinementSummary'], @ischar);
parser.addParameter('infoFilePath', '', @ischar);
parser.addParameter('inputDataFolder', '', @ischar);
parser.addParameter('numWorkers', 2, @isnumeric);
parser.addParameter('reconVersion', 'Reconstructions', @ischar);
parser.addParameter('createSBML', false, @islogical);


parser.parse(draftFolder, varargin{:});

draftFolder = parser.Results.draftFolder;
translateModels = parser.Results.translateModels;
refinedFolder = parser.Results.refinedFolder;
translatedDraftsFolder = parser.Results.translatedDraftsFolder;
summaryFolder = parser.Results.summaryFolder;
infoFilePath = parser.Results.infoFilePath;
inputDataFolder = parser.Results.inputDataFolder;
numWorkers = parser.Results.numWorkers;
reconVersion = parser.Results.reconVersion;
createSBML = parser.Results.createSBML;

if isempty(infoFilePath)
    % create a file with reconstruction names based on file names. Note:
    % this will lack taxonomy information.
    infoFile={'MicrobeID'};
    % Get all models from the input folder
    dInfo = dir(fullfile(draftFolder, '**/*.*'));  %get list of files and folders in any subfolder
    dInfo = dInfo(~[dInfo.isdir]);
    models={dInfo.name};
    models=models';
    % remove any files that are not SBML or mat files
    delInd=find(~any(contains(models(:,1),{'sbml','mat'})));
    models(delInd,:)=[];
    for i=1:length(models)
        infoFile{i+1,1}=adaptDraftModelID(models{i});
    end
    writetable(cell2table(infoFile),[pwd filesep 'infoFile.txt'],'FileType','text','WriteVariableNames',false,'Delimiter','tab');
    infoFilePath = [pwd filesep 'infoFile.txt'];
end

% create folders where output data will be saved
mkdir(refinedFolder)
if translateModels
    mkdir(translatedDraftsFolder)
end
mkdir(summaryFolder)

%% prepare pipeline run
% Get all models from the input folder
dInfo = dir(fullfile(draftFolder, '**/*.*'));  %get list of files and folders in any subfolder
dInfo = dInfo(~[dInfo.isdir]);
models={dInfo.name};
models=models';
folders={dInfo.folder};
folders=folders';
% remove any files that are not SBML or mat files
delInd=find(~any(contains(models(:,1),{'sbml','mat'})));
models(delInd,:)=[];
folders(delInd,:)=[];
delInd=find((contains(models(:,1),{'DS_Store'})));
models(delInd,:)=[];
folders(delInd,:)=[];
% remove duplicates if there are any
for i=1:length(models)
    outputNamesToTest{i,1}=adaptDraftModelID(models{i,1});
end
[C,IA]=unique(outputNamesToTest);
models=models(IA);
folders=folders(IA);
outputNamesToTest=outputNamesToTest(IA);

% get already refined reconstructions
dInfo = dir(refinedFolder);
modelList={dInfo.name};
modelList=modelList';
if size(modelList,1)>0
    modelList(~contains(modelList(:,1),'.mat'),:)=[];
    modelList(:,1)=strrep(modelList(:,1),'.mat','');

    % remove models that were already created
    [C,IA]=intersect(outputNamesToTest(:,1),modelList(:,1));
    if ~isempty(C)
        models(IA,:)=[];
        folders(IA,:)=[];
    end
end

%% load the results from existing pipeline run and restart from there
if isfile([summaryFolder filesep 'summaries_' reconVersion '.mat'])
    load([summaryFolder filesep 'summaries_' reconVersion '.mat']);
else
    summaries=struct;
end

%% initialize COBRA Toolbox and parallel pool
global CBT_LP_SOLVER
if isempty(CBT_LP_SOLVER)
    initCobraToolbox
end
solver = CBT_LP_SOLVER;

if numWorkers>0 && ~isempty(ver('parallel'))
    % with parallelization
    poolobj = gcp('nocreate');
    if isempty(poolobj)
        parpool(numWorkers)
    end
end
environment = getEnvironment();


%% First part: refine all draft reconstructions in the input folder

% define the intervals in which the refining and regular saving will be
% performed
if length(models)>200
    steps=100;
else
    steps=25;
end

for i=1:steps:length(models)
    if length(models)-i>=steps-1
        endPnt=steps-1;
    else
        endPnt=length(models)-i;
    end

    modelsTmp = {};
    draftModelsTmp = {};
    summariesTmp = {};

    parfor j=i:i+endPnt
%for j=i:i+endPnt
        restoreEnvironment(environment);
        changeCobraSolver(solver, 'LP', 0, -1);

        % create an appropriate ID for the model
        microbeID=adaptDraftModelID(models{j});

        % load the model
        try
            draftModel = readCbModel([folders{j} filesep models{j}]);
        catch
            draftModel = load([folders{j} filesep models{j}]);
            F = fieldnames(draftModel);
            draftModel = draftModel.(F{1});
        end
        %% create the model
        [model,summary]=refinementPipeline(draftModel,microbeID, infoFilePath, inputDataFolder, translateModels);
        modelsTmp{j}=model;
        summariesTmp{j}=summary;

        outputFileNamesTmp{j,1}=microbeID;

        %% save translated version of the draft model as a mat file
        if contains(models{j},'sbml') && translateModels
            draftModel = translateDraftReconstruction(draftModel);
            draftModelsTmp{j}=draftModel;
        end
    end
    % save the data
    for j=i:i+endPnt
        model=modelsTmp{j};
        writeCbModel(model, 'format', 'mat', 'fileName', [refinedFolder filesep outputFileNamesTmp{j,1}]);
        if contains(models{j},'sbml') || contains(models{j},'xml')
            % save translated version of the draft model as a mat file, otherwise keep the orinal mat file
            model=draftModelsTmp{j};
            writeCbModel(model, 'format', 'mat', 'fileName', [translatedDraftsFolder filesep outputFileNamesTmp{j,1}]);
        end
        summaries.(['m_' outputFileNamesTmp{j,1}])=summariesTmp{j};
    end
    save([summaryFolder filesep 'summaries_' reconVersion],'summaries');
end

%% Get summary of curation efforts performed
orgs=fieldnames(summaries);
pipelineFields={};
for i=1:length(orgs)
    pipelineFields=union(pipelineFields,fieldnames(summaries.(orgs{i})));
end
pipelineFields=unique(pipelineFields);
for i=1:length(pipelineFields)
    for j=1:length(orgs)
        pipelineSummary.(pipelineFields{i,1}){j,1}=orgs{j};
        if isfield(summaries.(orgs{j}),pipelineFields{i,1})
            if ~isempty(summaries.(orgs{j}).(pipelineFields{i,1}))
                if isnumeric(summaries.(orgs{j}).(pipelineFields{i,1}))
                    pipelineSummary.(pipelineFields{i,1}){j,2}=num2str(summaries.(orgs{j}).(pipelineFields{i,1}));
                elseif ischar(summaries.(orgs{j}).(pipelineFields{i,1}))
                    pipelineSummary.(pipelineFields{i,1}){j,2}=summaries.(orgs{j}).(pipelineFields{i,1});
                else
                    pipelineSummary.(pipelineFields{i,1})(j,2:length(summaries.(orgs{j}).(pipelineFields{i,1}))+1)=summaries.(orgs{j}).(pipelineFields{i,1})';
                end
            end
        end
    end
    if any(strcmp(pipelineFields{i,1},{'untranslatedMets','untranslatedRxns'}))
        cases={};
        spreadsheet=pipelineSummary.(pipelineFields{i});
        for j=1:size(spreadsheet,1)
            nonempty=spreadsheet(j,find(~cellfun(@isempty,spreadsheet(j,:))));
            for k=2:length(nonempty)
                cases{length(cases)+1}=nonempty{k};
            end
        end
        spreadsheet=unique(cases)';
        spreadsheet=cell2table(spreadsheet);
        if size(spreadsheet,1)>0
            writetable(spreadsheet,[summaryFolder filesep pipelineFields{i,1}],'FileType','text','WriteVariableNames',false,'Delimiter','tab');
        end
    else
        spreadsheet=cell2table(pipelineSummary.(pipelineFields{i}));
        if size(spreadsheet,2)>1
            writetable(spreadsheet,[summaryFolder filesep pipelineFields{i,1}],'FileType','text','WriteVariableNames',false,'Delimiter','tab');
        end
    end
end

% delete unneeded files
delete('rBioNetDB.mat');

%% create SBML files (default=not created)

if createSBML
    sbmlFolder = [pwd filesep refinedFolder '_SBML'];
    createSBMLFiles(refinedFolder, sbmlFolder)
end

end

