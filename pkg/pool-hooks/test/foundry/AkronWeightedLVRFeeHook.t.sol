// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { PoolRoleAccounts } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { WeightedPool } from "@balancer-labs/v3-pool-weighted/contracts/WeightedPool.sol";

import { WeightedPoolFactory } from "@balancer-labs/v3-pool-weighted/contracts/WeightedPoolFactory.sol";
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { StableMath } from "@balancer-labs/v3-solidity-utils/contracts/math/StableMath.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { ScalingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import { PoolSwapParams, SwapKind } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { AkronWeightedLVRFeeHook } from "../../contracts/AkronWeightedLVRFeeHook.sol";
import { AkronWeightedMathMock } from "../../contracts/test/AkronWeightedMathMock.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract E2eSwapWeightedTest is BaseVaultTest {
    using ArrayHelpers for *;
    using CastingHelpers for *;
    using FixedPoint for uint256;

    uint256 internal daiIdx;
    uint256 internal usdcIdx;

    AkronWeightedLVRFeeHook internal akronWeightedLVRFeeHook;

    AkronWeightedMathMock akronWeightedMathMock = new AkronWeightedMathMock();

    function setUp() public override {
        super.setUp();

        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));
        
    }

    function createPoolFactory() internal override returns (address) {
        return address(new WeightedPoolFactory(IVault(address(vault)), 365 days, "Factory v1", "Pool v1"));
    }

    function createHook() internal override returns (address) {
        akronWeightedLVRFeeHook = new AkronWeightedLVRFeeHook(IVault(address(vault)));
        vm.label(address(akronWeightedLVRFeeHook), "AkronWeightedLVRFeeHook");
        return address(akronWeightedLVRFeeHook);
    }

    function _createPool(
        address[] memory tokens,
        string memory label
    ) internal override returns (address newPool, bytes memory poolArgs) {
        PoolRoleAccounts memory roleAccounts;
        newPool = WeightedPoolFactory(poolFactory).create(
            "Akron Weighted Pool",
            "AKRONWEIGHTED",
            vault.buildTokenConfig(tokens.asIERC20()),
            [uint256(50e16), uint256(50e16)].toMemoryArray(),
            roleAccounts,
            0.001e16,
            address(akronWeightedLVRFeeHook),
            false,
            false,
            ZERO_BYTES32
        );

                
        vm.label(address(newPool), label);

        return (
            address(newPool),
            abi.encode(
                WeightedPool.NewPoolParams({
                    name: "Akron Weighted Pool",
                    symbol: "AKRONWEIGHTED",
                    numTokens: 2,
                    normalizedWeights: [uint256(50e16), uint256(50e16)].toMemoryArray(),
                    version: "Pool v1"
                }),
                vault
            )
        );
    }

    function testSwap__Fuzz(uint256 amountGivenScaled18, uint256 kindRaw) public {

        amountGivenScaled18 = bound(amountGivenScaled18, 1e18, poolInitAmount / 10);
        SwapKind kind = SwapKind(bound(kindRaw, 0, 1));

        swapFeePercentage = IBasePool(pool).getMinimumSwapFeePercentage();

        BaseVaultTest.Balances memory balancesBefore = getBalances(alice);

        if (kind == SwapKind.EXACT_IN) {
            vm.prank(alice);
            router.swapSingleTokenExactIn(
                pool, 
                usdc, 
                dai, 
                amountGivenScaled18, 
                0, 
                MAX_UINT256, 
                false, 
                bytes("")
            );
        } else {
            vm.prank(alice);
            router.swapSingleTokenExactOut(
                pool,
                usdc,
                dai,
                amountGivenScaled18,
                MAX_UINT256,
                MAX_UINT256,
                false,
                bytes("")
            );
        }
        
        uint256 actualSwapFeePercentage = _calculateFee(
            amountGivenScaled18,
            kind,
            [poolInitAmount, poolInitAmount].toMemoryArray(),
            WeightedPool(pool).getNormalizedWeights()
        );

        if (actualSwapFeePercentage < swapFeePercentage) actualSwapFeePercentage = swapFeePercentage;
        
        BaseVaultTest.Balances memory balancesAfter = getBalances(alice);

        uint256 actualAmountOut = balancesAfter.aliceTokens[daiIdx] - balancesBefore.aliceTokens[daiIdx];
        uint256 actualAmountIn = balancesBefore.aliceTokens[usdcIdx] - balancesAfter.aliceTokens[usdcIdx];
        
        vm.prank(address(vault));
        
        uint256 expectedAmountOut;
        uint256 expectedAmountIn;
        if (kind == SwapKind.EXACT_IN) {
            // extract swap fee
            expectedAmountIn = amountGivenScaled18;
            uint256 swapAmount = amountGivenScaled18.mulUp(actualSwapFeePercentage);

            uint256 amountCalculatedScaled18 = WeightedPool(pool).onSwap(
                PoolSwapParams({
                    kind: kind,
                    indexIn: usdcIdx,
                    indexOut: daiIdx,
                    amountGivenScaled18: expectedAmountIn - swapAmount,
                    balancesScaled18: [poolInitAmount, poolInitAmount].toMemoryArray(),
                    router: address(0),
                    userData: bytes("")
                })
            );

            expectedAmountOut = amountCalculatedScaled18;
        } else {
            expectedAmountOut = amountGivenScaled18;
            uint256 amountCalculatedScaled18 = WeightedPool(pool).onSwap(
                PoolSwapParams({
                    kind: kind,
                    indexIn: usdcIdx,
                    indexOut: daiIdx,
                    amountGivenScaled18: expectedAmountOut,
                    balancesScaled18: [poolInitAmount, poolInitAmount].toMemoryArray(),
                    router: address(0),
                    userData: bytes("")
                })
            );
            expectedAmountIn =
                amountCalculatedScaled18 +
                amountCalculatedScaled18.mulDivUp(actualSwapFeePercentage, actualSwapFeePercentage.complement());
        }

        assertEq(expectedAmountIn, actualAmountIn, "Amount in should be expectedAmountIn");
        assertEq(expectedAmountOut, actualAmountOut, "Amount out should be expectedAmountOut");
    }

    function _calculateFee(
        uint256 amountGivenScaled18,
        SwapKind kind,
        uint256[] memory balances,
        uint256[] memory weights
    ) internal view returns (uint256) {
        if (kind == SwapKind.EXACT_IN) {
            return akronWeightedMathMock.computeSwapFeePercentageGivenExactIn(
                balances[usdcIdx],
                weights[usdcIdx].divDown(weights[daiIdx]),
                amountGivenScaled18
            );
        } else {
            return akronWeightedMathMock.computeSwapFeePercentageGivenExactOut(
                balances[daiIdx],
                weights[daiIdx].divUp(weights[usdcIdx]),
                amountGivenScaled18
            );
        }
    }
}
