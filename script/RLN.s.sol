// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "../src/RLN.sol";
import "../src/Verifier.sol";

contract RLNScript is Script {
    function run() public {
        uint256 minimalDeposit = vm.envUint("MINIMAL_DEPOSIT");
        uint256 depth = vm.envUint("DEPTH");
        uint8 feePercentage = uint8(vm.envUint("FEE_PERCENTAGE"));
        address feeReceiver = vm.envAddress("FEE_RECEIVER");
        uint256 freezePeriod = vm.envUint("FREEZE_PERIOD");
        address token = vm.envAddress("ERC20TOKEN");

        vm.startBroadcast();

        Verifier verifier = new Verifier();
        RLN rln = new RLN(minimalDeposit, depth, feePercentage, feeReceiver, freezePeriod, token, address(verifier));

        vm.stopBroadcast();
    }
}
