// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultAdmin.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ArrayHelpers.sol";
import { ERC4626TestToken } from "@balancer-labs/v3-solidity-utils/contracts/test/ERC4626TestToken.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";

import { PoolFactoryMock } from "../../contracts/test/PoolFactoryMock.sol";
import { PoolMock } from "../../contracts/test/PoolMock.sol";

import { BaseVaultTest } from "./utils/BaseVaultTest.sol";

contract VaultTokenTest is BaseVaultTest {
    using ArrayHelpers for *;

    PoolFactoryMock poolFactory;

    ERC4626TestToken waDAI;
    ERC4626TestToken cDAI;
    ERC4626TestToken waUSDC;

    // For two-token pools with waDAI/waUSDC, keep track of sorted token order.
    uint256 internal waDaiIdx;
    uint256 internal waUsdcIdx;

    // Track the indices for the standard dai/usdc pool.
    uint256 internal daiIdx;
    uint256 internal usdcIdx;

    function setUp() public virtual override {
        BaseVaultTest.setUp();

        waDAI = new ERC4626TestToken(dai, "Wrapped aDAI", "waDAI", 18);
        cDAI = new ERC4626TestToken(dai, "Wrapped cDAI", "cDAI", 18);
        waUSDC = new ERC4626TestToken(usdc, "Wrapped aUSDC", "waUSDC", 6);

        poolFactory = new PoolFactoryMock(vault, 365 days);

        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));
        (waDaiIdx, waUsdcIdx) = getSortedIndexes(address(waDAI), address(waUSDC));

        pool = address(new PoolMock(IVault(address(vault)), "ERC20 Pool", "ERC20POOL"));
    }

    function createPool() internal pure override returns (address) {
        return address(0);
    }

    function initPool() internal override {
        // Do nothing for this test
    }

    function testGetRegularPoolTokens() public {
        registerBuffers();
        registerPool();

        IERC20[] memory tokens = vault.getPoolTokens(pool);

        assertEq(tokens.length, 2);

        assertEq(address(tokens[waDaiIdx]), address(waDAI));
        assertEq(address(tokens[waUsdcIdx]), address(waUSDC));
    }

    function testInvalidStandardTokenWithRateProvider() public {
        // Standard token with a rate provider is invalid
        TokenConfig[] memory tokenConfig = new TokenConfig[](2);
        tokenConfig[daiIdx].token = IERC20(dai);
        tokenConfig[0].rateProvider = IRateProvider(waDAI);
        tokenConfig[usdcIdx].token = IERC20(usdc);

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.InvalidTokenConfiguration.selector));
        _registerPool(tokenConfig);
    }

    function testInvalidRateTokenWithoutProvider() public {
        // Rated token without a rate provider is invalid

        (uint256 ethIdx, uint256 localUsdcIdx) = getSortedIndexes(address(wsteth), address(usdc));

        TokenConfig[] memory tokenConfig = new TokenConfig[](2);
        tokenConfig[ethIdx].token = IERC20(wsteth);
        tokenConfig[ethIdx].tokenType = TokenType.WITH_RATE;
        tokenConfig[localUsdcIdx].token = IERC20(usdc);

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.InvalidTokenConfiguration.selector));
        _registerPool(tokenConfig);
    }

    function registerBuffers() private {
        // Establish assets and supply so that buffer creation doesn't fail
        vm.startPrank(alice);

        dai.mint(address(alice), 2 * defaultAmount);

        dai.approve(address(waDAI), defaultAmount);
        waDAI.deposit(defaultAmount, address(alice));

        dai.approve(address(cDAI), defaultAmount);
        cDAI.deposit(defaultAmount, address(alice));

        usdc.mint(address(alice), defaultAmount);
        usdc.approve(address(waUSDC), defaultAmount);
        waUSDC.deposit(defaultAmount, address(alice));
        vm.stopPrank();
    }

    function registerPool() private {
        TokenConfig[] memory tokenConfig = new TokenConfig[](2);
        tokenConfig[waDaiIdx].token = IERC20(waDAI);
        tokenConfig[waUsdcIdx].token = IERC20(waUSDC);
        tokenConfig[0].tokenType = TokenType.WITH_RATE;
        tokenConfig[1].tokenType = TokenType.WITH_RATE;
        tokenConfig[waDaiIdx].rateProvider = IRateProvider(waDAI);
        tokenConfig[waUsdcIdx].rateProvider = IRateProvider(waUSDC);

        _registerPool(tokenConfig);
    }

    function _registerPool(TokenConfig[] memory tokenConfig) private {
        LiquidityManagement memory liquidityManagement;
        PoolHooks memory poolHooks;

        poolFactory.registerPool(
            pool,
            tokenConfig,
            PoolRoleAccounts({ pauseManager: address(0), swapFeeManager: address(0), poolCreator: address(0) }),
            poolHooks,
            liquidityManagement
        );
    }
}
