// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.6.12;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { WeightedPoolFactory } from "pool-weighted/contracts/WeightedPoolFactory.sol";
import { TokenConfig, TokenType, PoolRoleAccounts } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import "../contracts/AkronWeightedLVRFeeHook.sol";

contract DeployScript is Script {
    function run() external {
        
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        address account = vm.addr(privateKey);
        // vm.setNonce(account, 4);

        address vault = vm.envAddress("SEPOLIA_BALANCER_V3_VAULT_ADDRESS");
        address weightedFactory = vm.envAddress("SEPOLIA_BALANCER_V3_WEIGHTED_FACTORY_ADDRESS");
        address hook = vm.envAddress("SEPOLIA_BALANCER_V3_AKRON_HOOK_ADDRESS");
        
        IERC20 token0 = IERC20(vm.envAddress("SEPOLIA_TOKEN0_ADDRESS"));
        IERC20 token1 = IERC20(vm.envAddress("SEPOLIA_TOKEN1_ADDRESS"));
        
        
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(token0);
        tokens[1] = IERC20(token1);

        IRateProvider[] memory rateProviders = new IRateProvider[](2);
        rateProviders[0] = IRateProvider(address(0));
        rateProviders[1] = IRateProvider(address(0));


        bool[] memory yieldFeeFlags = new bool[](2);
        yieldFeeFlags[0] = false;
        yieldFeeFlags[1] = false;

        uint256[] memory weights = new uint256[](2);
        weights[0] = uint256(50e16);
        weights[1] = uint256(50e16);

        PoolRoleAccounts memory roleAccounts;
        roleAccounts.pauseManager = account;
        roleAccounts.swapFeeManager = account;
        roleAccounts.poolCreator = account;

        TokenConfig[] memory tokenConfig = new TokenConfig[](2);
        for (uint256 i = 0; i < tokenConfig.length; ++i) {
            tokenConfig[i].token = tokens[i];
            tokenConfig[i].rateProvider = rateProviders[i];
            tokenConfig[i].tokenType = rateProviders[i] == IRateProvider(address(0))
                ? TokenType.STANDARD
                : TokenType.WITH_RATE;
            tokenConfig[i].paysYieldFees = yieldFeeFlags[i];
        }

        vm.startBroadcast(privateKey);


        // AkronWeightedLVRFeeHook hook = new AkronWeightedLVRFeeHook(IVault(vault), weightedFactory); 
        // hook address : 0x40Cbdf84475f8Dd7C9a9c665eDE551EeaaF21F8d


        WeightedPoolFactory(weightedFactory).create(
            "Akron Aave WETH-USDC",
            "Aave WETH-USDC",
            tokenConfig,
            weights,
            roleAccounts,
            1e18 / 10000,
            hook,
            true,
            false,
            bytes32(0)
        );
        
        vm.stopBroadcast();

        // console.log("akronLVRFeeHook:", address(hook));

    }
}