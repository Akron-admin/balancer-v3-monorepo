// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

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

        _gyroPool = new Gyro2CLPPool(
            Gyro2CLPPool.GyroParams({
                name: "GyroPool",
                symbol: "GRP",
                sqrtAlpha: _sqrtAlpha,
                sqrtBeta: _sqrtBeta
            }),
            vault
        );
        vm.label(address(_gyroPool), "GyroPool");
    }

    function testComputeNewXBalance__Fuzz(uint256 balanceX, uint256 balanceY, uint256 deltaX) public {
        balanceX = bound(balanceX, 1e16, 1e27);
        // Price range is [alpha,beta], so balanceY needs to be between alpha*balanceX and beta*balanceX
        balanceY = bound(
            balanceY,
            balanceX.mulDown(_sqrtAlpha).mulDown(_sqrtAlpha),
            balanceX.mulDown(_sqrtBeta).mulDown(_sqrtBeta)
        );
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

        // 0.000000000001% error
        assertApproxEqRel(newXBalance, balanceX + deltaX, 1e4);
    }

    function testComputeNewYBalance__Fuzz(uint256 balanceX, uint256 balanceY, uint256 deltaY) public {
        balanceX = bound(balanceX, 1e16, 1e27);
        // Price range is [alpha,beta], so balanceY needs to be between alpha*balanceX and beta*balanceX
        balanceY = bound(
            balanceY,
            balanceX.mulDown(_sqrtAlpha).mulDown(_sqrtAlpha),
            balanceX.mulDown(_sqrtBeta).mulDown(_sqrtBeta)
        );
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

        // 0.000000000001% error
        assertApproxEqRel(newYBalance, balanceY + deltaY, 1e4);
    }
}
