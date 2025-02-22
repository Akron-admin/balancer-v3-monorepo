// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { BaseContractsDeployer } from "@balancer-labs/v3-solidity-utils/test/foundry/utils/BaseContractsDeployer.sol";

import { AkronWeightedPoolFactory } from "@balancer-labs/v3-pool-hooks/contracts/AkronWeightedPoolFactory.sol";

/**
 * @dev This contract contains functions for deploying mocks and contracts related to the "StablePool". These functions should have support for reusing artifacts from the hardhat compilation.
 */
contract AkronWeightedPoolFactoryDeployer is BaseContractsDeployer {
    string private artifactsRootDir = "artifacts/";

    constructor() {
        // if this external artifact path exists, it means we are running outside of this repo
        if (vm.exists("artifacts/@balancer-labs/v3-pool-hooks/")) {
            artifactsRootDir = "artifacts/@balancer-labs/v3-pool-hooks/";
        }
    }

    function deployAkronWeightedPoolFactory(
        IVault vault,
        uint32 pauseWindowDuration,
        string memory factoryVersion,
        string memory poolVersion
    ) internal returns (AkronWeightedPoolFactory) {
        if (reusingArtifacts) {
            return
                AkronWeightedPoolFactory(
                    deployCode(
                        "artifacts/contracts/AkronWeightedPoolFactory.sol/AkronWeightedPoolFactory.json",
                        abi.encode(
                            vault,
                            pauseWindowDuration,
                            factoryVersion,
                            poolVersion
                        )
                    )
                );
        } else {
            return
                new AkronWeightedPoolFactory(
                    vault,
                    pauseWindowDuration,
                    factoryVersion,
                    poolVersion
                );
        }
    }

    function _computeStablePoolPath(string memory name) private view returns (string memory) {
        return string(abi.encodePacked(artifactsRootDir, "contracts/", name, ".sol/", name, ".json"));
    }
}
