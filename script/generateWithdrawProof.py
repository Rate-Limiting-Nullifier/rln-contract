import subprocess
import os
def generateProof(artefactPath):
    generateWitnessCmd = "node " + artefactPath + "/generate_witness.js " + artefactPath + "/withdraw.wasm " + artefactPath + "/input.json " + artefactPath + "/witness.wtns"
    generateProofCmd = "snarkjs groth16 prove  " + artefactPath + "/final.zkey  " + artefactPath + "/witness.wtns  " + artefactPath + "/proof.json  " + artefactPath + "/public.json"
    #generateCallCmd = "cd " + artefactPath + " && snarkjs generatecall"
    

    witnessGenerateResp = subprocess.call(generateWitnessCmd,shell=True)
    proofGenerateResp = subprocess.call(generateProofCmd,shell=True)
    #allGenerateResp = subprocess.call(generateCallCmd,shell=True)
    respStr = ""
    with open(artefactPath+"/proof.json") as file:
        file_path = os.path.dirname(file.name)
        for item in file:
            if len(item)> 25:
                respStr += item.replace(" ","").replace(",","").replace("\r\n","").replace("\t","").replace("\"","") + ","

    print(respStr.replace(chr(32), ""))

def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("artefactPath", help="The full path to the artefact directory")
    args = parser.parse_args()
    generateProof(args.artefactPath)

main()
