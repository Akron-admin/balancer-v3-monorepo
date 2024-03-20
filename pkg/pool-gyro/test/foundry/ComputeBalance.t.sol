// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { Gyro2CLPPool } from "../../contracts/Gyro2CLPPool.sol";

import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

contract ComputeBalanceTest is BaseVaultTest {
    using FixedPoint for uint256;

    Gyro2CLPPool private _gyroPool;
    uint256 private _sqrtAlpha = 1e18;
    uint256 private _sqrtBeta = 100e18;

    function setUp() public virtual override {
        BaseVaultTest.setUp();

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = dai;
        tokens[1] = wsteth;

        _gyroPool = new Gyro2CLPPool(
            Gyro2CLPPool.GyroParams({
                name: 'GyroPool',
                symbol: 'GRP',
                tokens: tokens,
                sqrtAlpha: _sqrtAlpha,
                sqrtBeta: _sqrtBeta
            }),
            vault
        );
        vm.label(address(_gyroPool), 'GyroPool');
    }

    function testComputeNewXBalance__Fuzz(uint256 balanceX, uint256 balanceY, uint256 deltaX) public {
        balanceX = bound(balanceX, 1e16, 1e27);
        balanceY = bound(balanceY, 1e16, 1e27);
        uint256[] memory balances = new uint256[](2);
        balances[0] = balanceX;
        balances[1] = balanceY;
        uint256 oldInvariant = _gyroPool.computeInvariant(balances);

        deltaX = bound(deltaX, 1e16, 1e30);
        balances[0] = balances[0] + deltaX;
        uint256 newInvariant = _gyroPool.computeInvariant(balances);
        balances[0] = balances[0] - deltaX;

        uint256 invariantRatio = newInvariant.divDown(oldInvariant);
        uint256 newXBalance = _gyroPool.computeBalance(balances, 0, invariantRatio);

        // 0.1% error
        assertApproxEqRel(newXBalance, balanceX + deltaX, 1e15);
    }

    function testComputeNewYBalance__Fuzz(uint256 balanceX, uint256 balanceY, uint256 deltaY) public {
        balanceX = bound(balanceX, 1e16, 1e27);
        balanceY = bound(balanceY, 1e16, 1e27);
        uint256[] memory balances = new uint256[](2);
        balances[0] = balanceX;
        balances[1] = balanceY;
        uint256 oldInvariant = _gyroPool.computeInvariant(balances);

        deltaY = bound(deltaY, 1e16, 1e30);
        balances[1] = balances[1] + deltaY;
        uint256 newInvariant = _gyroPool.computeInvariant(balances);
        balances[1] = balances[1] - deltaY;

        uint256 invariantRatio = newInvariant.divDown(oldInvariant);
        uint256 newYBalance = _gyroPool.computeBalance(balances, 1, invariantRatio);

        // 0.1% error
        assertApproxEqRel(newYBalance, balanceY + deltaY, 1e15);
    }
}