// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { IVersion } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IVersion.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { BalancerPoolToken } from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { AkronWeightedPoolFactoryDeployer } from "./utils/AkronWeightedPoolFactoryDeployer.sol";
import { AkronWeightedPoolFactory } from "../../contracts/AkronWeightedPoolFactory.sol";

contract AkronWeightedPoolFactoryTest is BaseVaultTest, AkronWeightedPoolFactoryDeployer {
    using CastingHelpers for address[];
    using ArrayHelpers for *;

    string private constant FACTORY_VERSION = '{"name":"AkronWeightedPoolFactory","version":1,"deployment":"20250204-v3-akron-weighted-pool"}';
    string private constant POOL_VERSION = '{"name":"AkronWeightedPool","version":1,"deployment":"20250204-v3-akron-weighted-pool"}';

    uint256 internal daiIdx;
    uint256 internal usdcIdx;

    AkronWeightedPoolFactory internal weightedPoolFactory;

    function setUp() public override {
        super.setUp();

        weightedPoolFactory = deployAkronWeightedPoolFactory(
            IVault(address(vault)),
            365 days,
            FACTORY_VERSION,
            POOL_VERSION
        );
        vm.label(address(weightedPoolFactory), "weighted pool factory");

        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));
    }

    function testFactoryHasHook() public {
        address akronWeightedHook = weightedPoolFactory.getAkronWeightedLVRFeeHook();
        assertNotEq(akronWeightedHook, address(0), "No akron hook deployed");

        address weightedPool = _deployAndInitializeWeightedPool(false);
        HooksConfig memory config = vault.getHooksConfig(weightedPool);

        assertEq(config.hooksContract, akronWeightedHook, "Hook contract mismatch");
    }

    function testVersions() public {
        address weightedPool = _deployAndInitializeWeightedPool(false);

        assertEq(IVersion(weightedPoolFactory).version(), FACTORY_VERSION, "Wrong factory version");
        assertEq(weightedPoolFactory.getPoolVersion(), POOL_VERSION, "Wrong pool version in factory");
        assertEq(IVersion(weightedPool).version(), POOL_VERSION, "Wrong pool version in pool");
    }

    function testFactoryPausedState() public view {
        uint32 pauseWindowDuration = weightedPoolFactory.getPauseWindowDuration();
        assertEq(pauseWindowDuration, 365 days);
    }

    function testCreatePoolWithoutDonation() public {
        address weightedPool = _deployAndInitializeWeightedPool(false);

        // Try to donate but fails because pool does not support donations
        vm.prank(bob);
        vm.expectRevert(IVaultErrors.DoesNotSupportDonation.selector);
        router.donate(weightedPool, [poolInitAmount, poolInitAmount].toMemoryArray(), false, bytes(""));
    }

    function testCreatePoolWithDonation() public {
        uint256 amountToDonate = poolInitAmount;

        address weightedPool = _deployAndInitializeWeightedPool(true);

        HookTestLocals memory vars = _createHookTestLocals(weightedPool);

        // Donates to pool successfully
        vm.prank(bob);
        router.donate(weightedPool, [amountToDonate, amountToDonate].toMemoryArray(), false, bytes(""));

        _fillAfterHookTestLocals(vars, weightedPool);

        // Bob balances
        assertEq(vars.bob.daiBefore - vars.bob.daiAfter, amountToDonate, "Bob DAI balance is wrong");
        assertEq(vars.bob.usdcBefore - vars.bob.usdcAfter, amountToDonate, "Bob USDC balance is wrong");
        assertEq(vars.bob.bptAfter, vars.bob.bptBefore, "Bob BPT balance is wrong");

        // Pool balances
        assertEq(vars.poolAfter[daiIdx] - vars.poolBefore[daiIdx], amountToDonate, "Pool DAI balance is wrong");
        assertEq(vars.poolAfter[usdcIdx] - vars.poolBefore[usdcIdx], amountToDonate, "Pool USDC balance is wrong");
        assertEq(vars.bptSupplyAfter, vars.bptSupplyBefore, "Pool BPT supply is wrong");

        // Vault Balances
        assertEq(vars.vault.daiAfter - vars.vault.daiBefore, amountToDonate, "Vault DAI balance is wrong");
        assertEq(vars.vault.usdcAfter - vars.vault.usdcBefore, amountToDonate, "Vault USDC balance is wrong");
    }

    function _deployAndInitializeWeightedPool(bool supportsDonation) private returns (address) {
        IERC20[] memory tokens = [address(dai), address(usdc)].toMemoryArray().asIERC20();
        uint256[] memory weights = [uint256(50e16), uint256(50e16)].toMemoryArray();

        address weightedPool = weightedPoolFactory.create(
            supportsDonation ? "Pool With Donation" : "Pool Without Donation",
            supportsDonation ? "PwD" : "PwoD",
            vault.buildTokenConfig(tokens),
            weights,
            supportsDonation,
            false, // Do not disable unbalanced add/remove liquidity
            ZERO_BYTES32
        );

        // Initialize pool
        vm.prank(lp);
        router.initialize(weightedPool, tokens, [poolInitAmount, poolInitAmount].toMemoryArray(), 0, false, bytes(""));

        return weightedPool;
    }

    struct WalletState {
        uint256 daiBefore;
        uint256 daiAfter;
        uint256 usdcBefore;
        uint256 usdcAfter;
        uint256 bptBefore;
        uint256 bptAfter;
    }

    struct HookTestLocals {
        WalletState bob;
        WalletState hook;
        WalletState vault;
        uint256[] poolBefore;
        uint256[] poolAfter;
        uint256 bptSupplyBefore;
        uint256 bptSupplyAfter;
    }

    function _createHookTestLocals(address pool) private view returns (HookTestLocals memory vars) {
        vars.bob.daiBefore = dai.balanceOf(bob);
        vars.bob.usdcBefore = usdc.balanceOf(bob);
        vars.bob.bptBefore = IERC20(pool).balanceOf(bob);
        vars.vault.daiBefore = dai.balanceOf(address(vault));
        vars.vault.usdcBefore = usdc.balanceOf(address(vault));
        vars.poolBefore = vault.getRawBalances(pool);
        vars.bptSupplyBefore = BalancerPoolToken(pool).totalSupply();
    }

    function _fillAfterHookTestLocals(HookTestLocals memory vars, address pool) private view {
        vars.bob.daiAfter = dai.balanceOf(bob);
        vars.bob.usdcAfter = usdc.balanceOf(bob);
        vars.bob.bptAfter = IERC20(pool).balanceOf(bob);
        vars.vault.daiAfter = dai.balanceOf(address(vault));
        vars.vault.usdcAfter = usdc.balanceOf(address(vault));
        vars.poolAfter = vault.getRawBalances(pool);
        vars.bptSupplyAfter = BalancerPoolToken(pool).totalSupply();
    }
}
