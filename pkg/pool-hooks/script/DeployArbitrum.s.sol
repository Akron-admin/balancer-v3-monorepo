// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.6.12;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import "../contracts/AkronWeightedLVRFeeHook.sol";

contract DeployScript is Script {
    function run() external {
        
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        // address account = vm.addr(privateKey);

        address vault = vm.envAddress("ARBITRUM_ONE_BALANCER_V3_VAULT_ADDRESS");
        address weightedFactory = vm.envAddress("ARBITRUM_ONE_BALANCER_V3_WEIGHTED_FACTORY_ADDRESS");

        vm.startBroadcast(privateKey);

        // AkronWeightedLVRFeeHook hook = new AkronWeightedLVRFeeHook(IVault(vault), weightedFactory); 
        // hook address : 0x40Cbdf84475f8Dd7C9a9c665eDE551EeaaF21F8d


        vm.stopBroadcast();

        // console.log("deployer:", account);
        // console.log("akronLVRFeeHook:", address(hook));
        

    }
}