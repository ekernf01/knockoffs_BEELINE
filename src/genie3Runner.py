import os
import pandas as pd
from pathlib import Path
import numpy as np

def generateInputs(RunnerObj):
    '''
    Function to generate desired inputs for GENIE3.
    If the folder/files under RunnerObj.datadir exist, 
    this function will not do anything.
    '''
    if not RunnerObj.inputDir.joinpath("GENIE3").exists():
        print("Input folder for GENIE3 does not exist, creating input folder...")
        RunnerObj.inputDir.joinpath("GENIE3").mkdir(exist_ok = False)
        
    if not RunnerObj.inputDir.joinpath("GENIE3/ExpressionData.csv").exists():
        ExpressionData = pd.read_csv(RunnerObj.inputDir.joinpath('ExpressionData.csv'),
                                     header = 0, index_col = 0)

        # Write .csv file
        ExpressionData.T.to_csv(RunnerObj.inputDir.joinpath("GENIE3/ExpressionData.csv"),
                             sep = '\t', header  = True, index = True)
    
def run(RunnerObj):
    '''
    Function to run GENIE3 algorithm
    '''
    inputPath = "data/" + str(RunnerObj.inputDir).split("RNMethods/")[1] + \
                    "/GENIE3/ExpressionData.csv"
    
    # make output dirs if they do not exist:
    outDir = "outputs/"+str(RunnerObj.inputDir).split("inputs/")[1]+"/GENIE3/"
    os.makedirs(outDir, exist_ok = True)
    
    outPath = "data/" +  str(outDir) + 'outFile.txt'
    cmdToRun = ' '.join(['docker run --rm -v', str(Path.cwd())+':/data/ --expose=41269', 
                         'arboreto:base /bin/sh -c \"python runArboreto.py --algo=GENIE3',
                         '--inFile='+inputPath, '--outFile='+outPath, '\"'])
    print(cmdToRun)
    os.system(cmdToRun)



def parseOutput(RunnerObj):
    '''
    Function to parse outputs from GENIE3.
    '''
    # Quit if output directory does not exist
    outDir = "outputs/"+str(RunnerObj.inputDir).split("inputs/")[1]+"/GENIE3/"
    if not Path(outDir).exists():
        raise FileNotFoundError()
        
    # Read output
    OutDF = pd.read_csv(outDir+'outFile.txt', sep = '\t', header = 0)
    
    outFile = open(outDir + 'rankedEdges.csv','w')
    outFile.write('Gene1'+'\t'+'Gene2'+'\t'+'EdgeWeight'+'\n')

    for idx, row in OutDF.iterrows():
        outFile.write('\t'.join([row['TF'],row['target'],str(row['importance'])])+'\n')
    outFile.close()
    