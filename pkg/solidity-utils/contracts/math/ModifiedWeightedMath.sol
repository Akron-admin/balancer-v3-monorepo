// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { FixedPoint } from "./FixedPoint.sol";

library ModifiedWeightedMath {
    using FixedPoint for uint256;

    /// @notice User attempted to extract a disproportionate amountOut of tokens from a pool.
    error MaxOutRatio();

    /// @notice User attempted to add a disproportionate amountIn of tokens to a pool.
    error MaxInRatio();

    // Swap limits: amounts swapped may not be larger than this percentage of the total balance.
    uint256 internal constant _MAX_IN_RATIO = 30e16; // 30%
    uint256 internal constant _MAX_OUT_RATIO = 30e16; // 30%

    /**
     * @notice Compute the `amountOut` of tokenOut in a swap, given the current balances and weights.
     * @param balanceIn The current balance of `tokenIn`
     * @param weightIn  The weight of `tokenIn`
     * @param balanceOut The current balance of `tokenOut`
     * @param weightOut The weight of `tokenOut`
     * @param amountIn The exact amount of `tokenIn` (i.e., the amount given in an ExactIn swap)
     * @return amountOut The calculated amount of `tokenOut` returned in an ExactIn swap
     */
    function computeOutGivenExactIn(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountIn
    ) internal pure returns (uint256 amountOut) {
        /**********************************************************************************************
        // outGivenExactIn                                                                           //
        // aO = amountOut                                                                            //
        // bO = balanceOut                                                                           //
        // bI = balanceIn              /      /        bI + aI            \    (wI / wO) \           //
        // aI = amountIn    aO = bO * |  1 - | --------------------------  | ^            |          //
        // wI = weightIn               \      \     ( bI + aI * 2 )       /              /           //
        // wO = weightOut                                                                            //
        **********************************************************************************************/

        // Amount out, so we round down overall.

        // The multiplication rounds down, and the subtrahend (power) rounds up (so the base rounds up too).
        // Because (bI + aI) / (bI + aI * 2) <= 1, the exponent rounds down.

        // Cannot exceed maximum in ratio.
        if (amountIn > balanceIn.mulDown(_MAX_IN_RATIO)) {
            revert MaxInRatio();
        }

        uint256 denominator = balanceIn + amountIn * 2;
        uint256 base = (balanceIn + amountIn).divUp(denominator);
        uint256 exponent = weightIn.divDown(weightOut);
        uint256 power = base.powUp(exponent);

        // Because of rounding up, power can be greater than one. Using complement prevents reverts.
        return balanceOut.mulDown(power.complement());
    }

    /**
     * @notice Compute the `amountIn` of tokenIn in a swap, given the current balances and weights.
     * @param balanceIn The current balance of `tokenIn`
     * @param weightIn  The weight of `tokenIn`
     * @param balanceOut The current balance of `tokenOut`
     * @param weightOut The weight of `tokenOut`
     * @param amountOut The exact amount of `tokenOut` (i.e., the amount given in an ExactOut swap)
     * @return amountIn The calculated amount of `tokenIn` returned in an ExactOut swap
     */
    function computeInGivenExactOut(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountOut
    ) internal pure returns (uint256 amountIn) {
        /**********************************************************************************************
        // inGivenExactOut                                                                           //
        // aO = amountOut                                                                            //
        // bO = balanceOut                                                                           //
        // bI = balanceIn              /  /        bO - aO            \    (wO / wI)      \          //
        // aI = amountIn    aI = bI * |  | --------------------------  | ^            - 1  |         //
        // wI = weightIn               \  \     ( bO - aO * 2)        /                   /          //
        // wO = weightOut                                                                            //
        **********************************************************************************************/

        // Amount in, so we round up overall.

        // The multiplication rounds up, and the power rounds up (so the base rounds up too).
        // Because (b0 - aO) / (b0 - a0 * 2) >= 1, the exponent rounds up.

        // Cannot exceed maximum out ratio.
        if (amountOut > balanceOut.mulDown(_MAX_OUT_RATIO)) {
            revert MaxOutRatio();
        }

        uint256 base = (balanceOut - amountOut).divUp(balanceOut - amountOut * 2);
        uint256 exponent = weightOut.divUp(weightIn);
        uint256 power = base.powUp(exponent);

        // Because the base is larger than one (and the power rounds up), the power should always be larger than one, so
        // the following subtraction should never revert.
        uint256 ratio = power - FixedPoint.ONE;

        return balanceIn.mulUp(ratio);
    }

    /**
     * @notice Compute the `amountIn` of tokenIn in a swap, given the current balances and weights.
     * @param balanceIn The current balance of `tokenIn`
     * @param exponent The weight of `tokenIn` divided by the weight of `tokenOut`, rounded down
     * @param amountIn The exact amount of `tokenIn` (i.e., the amount given in an ExactIn swap)
     * @return swapFeePercentage The calculated swap Fee Percentage of `tokenIn` returned in an ExactIn swap
     */
    function computeSwapFeePercentageGivenExactIn(
        uint256 balanceIn,
        uint256 exponent,
        uint256 amountIn
    ) internal pure returns (uint256) {
        uint256 power = (balanceIn + amountIn).divUp(balanceIn + amountIn * 2).powUp(exponent);
        return 
            (power - balanceIn.divUp(balanceIn + amountIn).powUp(exponent))
                * FixedPoint.ONE * (balanceIn + amountIn) 
                / ((FixedPoint.ONE - (power.complement())) * amountIn);
    }

    /**
     * @notice Compute the `amountIn` of tokenIn in a swap, given the current balances and weights.
     * @param balanceIn The current balance of `tokenIn`
     * @param exponent The weight of `tokenIn` divided by the weight of `tokenOut`, rounded down
     * @param totalAmountIn The total exact amount of `tokenIn` (i.e., the amount given in an ExactIn swap)
     * @param lastAmountIn The last exact amount of `tokenIn` (i.e., the amount given in an ExactIn swap)
     * @return swapFeePercentage The calculated swap Fee Percentage of `tokenIn` returned in an ExactIn swap
     */
    function computeSwapFeePercentageGivenExactIn(
        uint256 balanceIn,
        uint256 exponent,
        uint256 totalAmountIn,
        uint256 lastAmountIn
    ) internal pure returns (uint256) {
        uint256 totalPower = (balanceIn + totalAmountIn).divUp(balanceIn + totalAmountIn * 2).powUp(exponent);
        uint256 lastPower = (balanceIn + lastAmountIn).divUp(balanceIn + lastAmountIn * 2).powUp(exponent);
        return 
            (
                totalPower - balanceIn.divUp(balanceIn + totalAmountIn).powUp(exponent)
                    - (lastPower - balanceIn.divUp(balanceIn + lastAmountIn).powUp(exponent))
            )
                * FixedPoint.ONE * (balanceIn + (totalAmountIn - lastAmountIn)) 
                / ((FixedPoint.ONE - (lastPower - totalPower)) * (totalAmountIn - lastAmountIn));
    }

    /**
     * @notice Compute the `amountIn` of tokenIn in a swap, given the current balances and weights.
     * @param balanceOut The current balance of `tokenOut`
     * @param exponent The weight of `tokenOut` divided by the weight of `tokenIn`, rounded up
     * @param amountOut The exact amount of `tokenOut` (i.e., the amount given in an ExactOut swap)
     * @return swapFeePercentage The calculated swap Fee Percentage of `tokenIn` returned in an ExactOut swap
     */
    function computeSwapFeePercentageGivenExactOut(
        uint256 balanceOut,
        uint256 exponent,
        uint256 amountOut
    ) internal pure returns (uint256) {

        uint256 power = (balanceOut - amountOut).divUp(balanceOut - amountOut * 2).powUp(exponent);

        return 
            (power - balanceOut.divUp(balanceOut - amountOut).powUp(exponent) ) 
                * FixedPoint.ONE 
                / (power - FixedPoint.ONE);
    }

    /**
     * @notice Compute the `amountIn` of tokenIn in a swap, given the current balances and weights.
     * @param balanceOut The current balance of `tokenOut`
     * @param exponent The weight of `tokenOut` divided by the weight of `tokenIn`, rounded up
     * @param totalAmountOut The total exact amount of `tokenOut` (i.e., the amount given in an ExactOut swap)
     * @param lastAmountOut The last exact amount of `tokenOut` (i.e., the amount given in an ExactOut swap)
     * @return swapFeePercentage The calculated swap Fee Percentage of `tokenIn` returned in an ExactOut swap
     */
    function computeSwapFeePercentageGivenExactOut(
        uint256 balanceOut,
        uint256 exponent,
        uint256 totalAmountOut,
        uint256 lastAmountOut
    ) internal pure returns (uint256) {
        
        uint256 totalPower = (balanceOut - totalAmountOut).divUp(balanceOut - totalAmountOut * 2).powUp(exponent);
        uint256 lastPower = (balanceOut - lastAmountOut).divUp(balanceOut - lastAmountOut * 2).powUp(exponent);
        return 
            (
                totalPower - balanceOut.divUp(balanceOut - totalAmountOut).powUp(exponent) 
                    - (lastPower - balanceOut.divUp(balanceOut - lastAmountOut).powUp(exponent))
            ) 
                * FixedPoint.ONE 
                / (totalPower - lastPower);
    }
}
