// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

library AkronWeightedMath {
    using FixedPoint for uint256;

    /**
     * @notice Compute the `swapFeePercentage` of tokenIn in a swap, given the current balances and weights.
     * @param balanceIn The current balance of `tokenIn`
     * @param exponent The weight of `tokenOut` divided by the weight of `tokenIn`, rounded up
     * @param amountIn The exact amount of `tokenIn` (i.e., the amount given in an ExactIn swap)
     * @return swapFeePercentage The calculated swap Fee Percentage of `tokenIn` returned in an ExactIn swap
     */
    function computeSwapFeePercentageGivenExactIn(
        uint256 balanceIn,
        uint256 exponent,
        uint256 amountIn
    ) internal pure returns (uint256) {
        /**********************************************************************************************
        // outGivenExactIn, with fees                                                                //
        // aO = amountOut                                                                            //
        // bO = balanceOut                                                                           //
        // bI = balanceIn              /      /            bI - aI        \    (wI / wO) \           //
        // aI = amountIn    aO = bO * |  1 - | --------------------------  | ^            |          //
        // wI = weightIn               \      \       ( bI + aI * 2 )     /              /           //
        // wO = weightOut                                                                            //
        **********************************************************************************************/

        // swapFee = outGivenExactIn(amountIn) - outGivenExactInWithFees(amountIn)

        // Amount in, so we round up overall.

        uint256 powerWithFees = (balanceIn + amountIn).divUp(balanceIn + amountIn * 2).powUp(exponent);
        uint256 powerWithoutFees = (balanceIn).divUp(balanceIn + amountIn).powUp(exponent);
        return exponent.mulDivUp(
            (balanceIn + amountIn).mulDivUp(powerWithFees - powerWithoutFees, powerWithFees),
            amountIn
        );

    }

    /**
     * @notice Compute the `swapFeePercentage` of tokenIn in a swap, given the current balances and weights.
     * @param balanceOut The current balance of `tokenOut`
     * @param exponent The weight of `tokenOut` divided by the weight of `tokenIn`, rounded up
     * @param amountOut The exact amount of `tokenOut` (i.e., the amount given in an ExactOut swap)
     * @return swapFeePercentage The calculated swap Fee Percentage of `tokenIn` returned in an ExactIn swap
     */
    function computeSwapFeePercentageGivenExactOut(
        uint256 balanceOut,
        uint256 exponent,
        uint256 amountOut
    ) internal pure returns (uint256) {
        /**********************************************************************************************
        // inGivenExactOut, with fees                                                                //
        // aO = amountOut                                                                            //
        // bO = balanceOut                                                                           //
        // bI = balanceIn              /  /        bO - aO            \    (wO / wI)      \          //
        // aI = amountIn    aI = bI * |  | --------------------------  | ^            - 1  |         //
        // wI = weightIn               \  \     ( bO - aO * 2)        /                   /          //
        // wO = weightOut                                                                            //
        **********************************************************************************************/
        
        // swapFee = inGivenExactOutWithFees(amountIn) - inGivenExactOut(amountIn)

        // Amount in, so we round up overall.
        
        uint256 powerWithFees = (balanceOut - amountOut).divUp(balanceOut - amountOut * 2).powUp(exponent);
        uint256 powerWithoutFees = (balanceOut).divUp(balanceOut - amountOut).powUp(exponent);
        return (powerWithFees - powerWithoutFees).divUp(powerWithFees - FixedPoint.ONE);
    }

}