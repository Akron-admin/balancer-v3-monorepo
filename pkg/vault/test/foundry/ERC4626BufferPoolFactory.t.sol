// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { VaultMockDeployer } from "vault/test/foundry/utils/VaultMockDeployer.sol";
import { VaultMock } from "vault/contracts/test/VaultMock.sol";
import { ERC4626BufferPoolFactory } from "vault/contracts/factories/ERC4626BufferPoolFactory.sol";

contract ERC4626BufferPoolFactoryTest is Test {
    VaultMock vault;
    ERC4626BufferPoolFactory factory;

    function setUp() public {
        vault = VaultMockDeployer.deploy();
        factory = new ERC4626BufferPoolFactory(IVault(address(vault)), 365 days);
    }

    function testFactoryPausedState() public {
        uint256 pauseWindowDuration = factory.getPauseWindowDuration();
        assertEq(pauseWindowDuration, 365 days);
    }
}
