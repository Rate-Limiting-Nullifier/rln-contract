// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "../src/RLN.sol";
import "../src/verifier.sol";
import "../src/RLNToken.sol";



// Declare the interface for the ffi cheatcode function
interface ffiInterface{
    function ffi(string[] calldata) external returns (bytes memory);
}
contract RLNTest is Test {
    // local variable for RLN contract
    RLN _rln;
    // local address variable for verifier contract
    address public _verfier;
    // local variable to hold the RLNToken
    RLNToken _rlntoken;
    // local addresses
    address _feeReciever = makeAddr("feeReceiver");
    address _alice = makeAddr("alice");

    function setUp() public {
        
    }

    function testRegisterSuccess() public {
        // change the path to the folder you have put the artefacts in
        _verfier = deployVerifier("/home/......../rln/circom-rln/zkeyFiles/rln/final.zkey","verifier.sol");
        _rlntoken = new RLNToken();
        _rln = new RLN(1,10,1,_feeReciever,1 hours,address(_rlntoken),_verfier);
        _rlntoken.mint(_alice,1000);

        vm.startPrank(_alice);
        _rlntoken.approve(address(_rln),1);
        uint256 secretIdentity = uint256(keccak256("secret"));
        _rln.register(secretIdentity,1);
        vm.stopPrank();
    }

    function testWithdrawSuccess() public {
        // change the path to the folder you have put the artefacts in
        _verfier = deployVerifier("/home/........./rln/circom-rln/zkeyFiles/witdraw/final.zkey","verifier.sol");
        _rlntoken = new RLNToken();
        _rln = new RLN(1,10,1,_feeReciever,1 hours,address(_rlntoken),_verfier);
        _rlntoken.mint(_alice,1000);
        
        vm.startPrank(_alice);
        _rlntoken.approve(address(_rln),1);
        uint256 secretIdentity = uint256(keccak256("secret"));
        _rln.register(secretIdentity,1);
        // change the path to the folder you have put the artefacts in
        uint256[8] memory _generatedProof = generateWithdrawProof("/home/....../rln/circom-rln/build/withdraw_js",secretIdentity,address(_alice));
        _rln.withdraw(secretIdentity,_generatedProof);
        vm.warp(block.timestamp + 2 hours);
        uint256 balanceBefore = _rlntoken.balanceOf(_alice);
        _rln.release(secretIdentity);
        uint256 balanceAfter = _rlntoken.balanceOf(_alice);
        assertGt(balanceAfter,balanceBefore);
        vm.stopPrank();
    }

    /// @dev Runs the forge ffi command to generate a new Verifier contract using snarkjs commands.
    /// the resulting contract will overwrite the verifier.sol in the src directory
    /// 
    ///
    /// @param _keyfilename: full path to the keyfile eg. /home/user/workspace/keyfiles/final.key;
    /// @param _contractName: should always be verifier.sol but leaving the option
    ///                       so that the function can be re-used in other scenarios.
    function deployVerifier(string memory _keyfilename,string memory _contractName) public returns (address){
        // Make sure the path is not empty
        require(bytes(_keyfilename).length > 0, "KeyFile name not specified");
        require(bytes(_contractName).length > 0, "Output solidity contract name not specified");
        // Instantiate the ffi interface
        ffiInterface ffiCheat = ffiInterface(HEVM_ADDRESS);

        // The string array input varaibles used by ffi
        string[] memory deployCommand = new string[](9);
        // The circom artefacts to use to export a Solidity contract.
        // The command is "snarkjs zkey export solidityverifier final.zkey verifier.sol"
        deployCommand[0] = "snarkjs";
        deployCommand[1] = "zkey";
        deployCommand[2] = "export";
        deployCommand[3] = "solidityverifier";
        deployCommand[4] = _keyfilename;
        deployCommand[5] = string.concat("./src/" ,_contractName);
        deployCommand[6] = "&&";
        deployCommand[7] = "forge";
        deployCommand[8] = "build";
        //console.log("path to contract is: ",string.concat("./src/" ,_contractName));
        // A local variable to hold the output bytecode
        bytes memory commandResponse = ffiCheat.ffi(deployCommand);
        assert(commandResponse.length > 0);
        Groth16Verifier localVerfier = new Groth16Verifier();
        return address(localVerfier);

    }

    /// @dev Runs the forge ffi command to generate a witness and proof for withdraw.
    /// the resulting numbers will be populated into a uin256[8] array
    /// 
    ///
    /// @param _arteFactPath: full path to the artefacts eg. /home/user/workspace/keyfiles/final.key;
    /// @param _identitySecret: the indentity secret used to register
    /// @param _receiver: the withdrawer's address
    /// 
    function generateWithdrawProof(string memory _arteFactPath,uint256 _identitySecret,address _receiver) public returns (uint256[8] memory){
        // Make sure the path is not empty
        require(bytes(_arteFactPath).length > 0, "Path to artefacts not specified");
        // Instantiate the ffi interface
        ffiInterface ffiCheat = ffiInterface(HEVM_ADDRESS);

        // First generate an input.json file with the correct values.
        // values need to be as indicated below
        /*************************************************
            signal input identitySecret;
            signal input address;
        //*************************************************/    
        string memory fileContents = string.concat('{"identitySecret": "',Strings.toString(_identitySecret),'","address": "',Strings.toHexString(uint256(uint160(_receiver)), 20),'"}');
        string memory filePath = string.concat(_arteFactPath,"/input.json");        
        vm.writeFile(filePath,fileContents);
        
        // Now run thew python script in the script directory to generate the witness proof and call
        // The command is "python3 generateWithdrawProof.py artefactPath"
        string[] memory witnessCreateCommand = new string[](3);
        witnessCreateCommand[0] = "python3";
        witnessCreateCommand[1] = "./script/generateWithdrawProof.py";
        witnessCreateCommand[2] = _arteFactPath;
        bytes memory commandResponse = ffiCheat.ffi(witnessCreateCommand);        

        uint256[8] memory respUint = subString(commandResponse);
        return respUint;

    }

    /// the helper function to substring the bytes returned by the ffi python call
    function subString(bytes memory inBytes) public returns (uint256[8] memory){
        uint256[8] memory respNums;
        uint256 counter;
        uint256 byteCounter;
        for(uint256 i;i<inBytes.length;i++){
            if(inBytes[i] == bytes1(0x2c)){
                uint256 len = (i-1)-byteCounter;
                uint256 tempNum;
                uint256 l;
                for(uint256 j = byteCounter; j< byteCounter + len; j++){
                    tempNum = tempNum + (byteToNum(inBytes[j]) * (10**(len-(l+1))));
                    l++;
                }
                respNums[counter] = tempNum;
                byteCounter = i+1;
                counter++;
            }           
            
        }
        return respNums;
    }

    /// helper function to convert bytes1 to a number between 0 and 9
    function byteToNum(bytes1  _inbyte) public returns(uint256 res) {

    if(_inbyte == bytes1(0x30)){
        res = 0;
    }
    if(_inbyte == bytes1(0x31)){
        res = 1;
    }
    if(_inbyte == bytes1(0x32)){
        res = 2;
    }
    if(_inbyte == bytes1(0x33)){
        res = 3;
    }
    if(_inbyte == bytes1(0x34)){
        res = 4;
    }
    if(_inbyte == bytes1(0x35)){
        res = 5;
    }
    if(_inbyte == bytes1(0x36)){
        res = 6;
    }
    if(_inbyte == bytes1(0x37)){
        res = 7;
    }
    if(_inbyte == bytes1(0x38)){
        res = 8;
    }
    if(_inbyte == bytes1(0x39)){
        res = 9;
    }
    return res;
}
}
