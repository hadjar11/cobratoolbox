function T = findFutileCycle(model, cut,closedModel)
% This function attempts to find reactions involved in the atp-driving
% futile cycle
% 
% INPUT
% model         model structure
% cut           cutoff value for reactions to be displayed
% closedModel   if 1 the model will be closed otw the applied medium
%               constraints count (DEFAULT:1);
% OUTPUT 
% T         Table of reactions potentially involved
%
% Ines Thiele 03/2022

if ~exist('cut','var')
    cut = 250;
end

if ~exist('closedModel','var')
    closedModel = 1;
end

modelClosed = model;
if closedModel
    modelexchanges1 = strmatch('Ex_',modelClosed.rxns);
    modelexchanges4 = strmatch('EX_',modelClosed.rxns);
    modelexchanges2 = strmatch('DM_',modelClosed.rxns);
    modelexchanges3 = strmatch('sink_',modelClosed.rxns);
    selExc = (find( full((sum(abs(modelClosed.S)==1,1) ==1) & (sum(modelClosed.S~=0) == 1))))';
    
    modelexchanges = unique([modelexchanges1;modelexchanges2;modelexchanges3;modelexchanges4;selExc]);
    modelClosed.lb(ismember(modelClosed.rxns,modelClosed.rxns(modelexchanges)))=0;
end
modelClosed = changeObjective(modelClosed,'DM_atp_c_');

fba = optimizeCbModel(modelClosed,'max','zero')
fba.v(find(abs(fba.v)<=1e-6))=0;
tab = [modelClosed.lb modelClosed.ub fba.v];
a = printRxnFormula(model);

R = model.rxns(find(abs(fba.v)>cut));
L = model.lb(find(abs(fba.v)>cut));
U = model.ub(find(abs(fba.v)>cut));
F = fba.v(find(abs(fba.v)>cut));
A = a(find(abs(fba.v)>cut));
if ~isempty(A)
T = table(R, num2str(L),num2str(U), num2str(F),A);
else
    T = {};
end