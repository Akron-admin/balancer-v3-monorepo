// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

library AkronMath {
    using FixedPoint for uint256;

    /**
     * @notice Compute the `swapFeePercentage` of tokenIn in a swap, given the current balances and weights.
     * @param balanceIn The current balance of `tokenIn`
     * @param lastBalanceIn The last balance of `tokenIn`
     * @param weightIn The weight of `tokenIn`
     * @param balanceOut The current balance of `tokenOut`
     * @param lastBalanceOut The last balance of `tokenOut`
     * @param weightOut The weight of `tokenOut`
     * @param amountIn The exact amount of `tokenIn` (i.e., the amount given in an ExactIn swap)
     * @return swapFeePercentage The calculated swap Fee Percentage of `tokenIn` returned in an ExactIn swap
     */
    function computeSwapFeePercentageGivenExactIn(
        uint256 balanceIn,
        uint256 lastBalanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 lastBalanceOut,
        uint256 weightOut,
        uint256 amountIn
    ) internal pure returns (uint256) {
        {
        // Compute normalized balances
        uint256 lastPx = (lastBalanceIn * weightOut).divDown(lastBalanceOut * weightIn);
        uint256 px = (balanceIn * weightOut).divDown(balanceOut * weightIn);
        
        // Compute normalized balanceIn by adding theoretical fees.
        // For example, if USDC is the input token, the last [USDC, ETH] reserves are [10000000, 33333] 
        // and current reserves are [102950, 333], then the normalized balanceIn would be around 104000.
        balanceIn = balanceOut.mulDown(weightIn) * (
            (px > lastPx ? px - lastPx : lastPx - px).powDown(FixedPoint.ONE * 2).divDown(lastPx * 4) + px
        ) / weightOut;
        
        uint256 lastInvariant = lastBalanceIn.powUp(weightIn).mulUp(lastBalanceOut.powUp(weightOut));
        uint256 invariant = balanceIn.powUp(weightIn).mulUp(balanceOut.powUp(weightOut));
        // Compute normalized lastBalances
        if (lastInvariant != invariant) {
            lastBalanceIn = lastBalanceIn.mulDivUp(invariant, lastInvariant);
            lastBalanceOut = lastBalanceOut * invariant / lastInvariant;
        }
        }

        // Compute swap fee percentage
        // The starting price is NOT the last price. Instead, it is derived from lastBalances, 
        // stored before the first swap of the block. For example, if the last trader, who happens to be
        // the first trader of the block, pushed the price of USDC/ETH from 3000 to 3050, 
        // and the current trader pushes the price from 3050 to 3200 in the same block, 
        // thus the current trader's swap fee would be the swap fee calculated from 3000 to 3200,
        // minus the swap fee calculated calculated from from 3000 to 3050.
        if (balanceIn > lastBalanceIn) {
            return getSwapFeePercentageGivenExactIn(
                    lastBalanceIn, 
                    weightIn.divDown(weightOut),
                    balanceIn - lastBalanceIn,
                    balanceIn - lastBalanceIn + amountIn
            );
        } else {
            return getSwapFeePercentageGivenExactIn(lastBalanceIn, weightIn.divDown(weightOut), 0, amountIn);
        }
    }

    /**
     * @notice Compute the `swapFeePercentage` of tokenIn in a swap, given the current balances and weights.
     * @param balanceIn The current balance of `tokenIn`
     * @param lastBalanceIn The last balance of `tokenIn`
     * @param weightIn The weight of `tokenIn`
     * @param balanceOut The current balance of `tokenOut`
     * @param lastBalanceOut The last balance of `tokenOut`
     * @param weightOut The weight of `tokenOut`
     * @param amountOut The exact amount of `tokenOut` (i.e., the amount given in an ExactOut swap)
     * @return swapFeePercentage The calculated swap Fee Percentage of `tokenIn` returned in an ExactIn swap
     */
    function computeSwapFeePercentageGivenExactOut(
        uint256 balanceIn,
        uint256 lastBalanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 lastBalanceOut,
        uint256 weightOut,
        uint256 amountOut
    ) internal pure returns (uint256) {
        {
        // Compute normalized balances
        uint256 lastPx = (lastBalanceIn * weightOut).divDown(lastBalanceOut * weightIn);
        uint256 px = (balanceIn * weightOut).divDown(balanceOut * weightIn);
        
        // Compute normalized balanceIn by adding theoretical fees.
        // For example, if USDC is the input token, the last [USDC, ETH] reserves are [10000000, 33333] 
        // and current reserves are [102950, 333], then the normalized balanceIn would be around 104000.
        balanceIn = balanceOut.mulDown(weightIn) * (
            (px > lastPx ? px - lastPx : lastPx - px).powDown(FixedPoint.ONE * 2).divDown(lastPx * 4) + px
        ) / weightOut;
        
        uint256 lastInvariant = lastBalanceIn.powUp(weightIn).mulUp(lastBalanceOut.powUp(weightOut));
        uint256 invariant = balanceIn.powUp(weightIn).mulUp(balanceOut.powUp(weightOut));
        // Compute normalized lastBalances
        if (lastInvariant != invariant) {
            lastBalanceIn = lastBalanceIn.mulDivUp(invariant, lastInvariant);
            lastBalanceOut = lastBalanceOut * invariant / lastInvariant;
        }
        }

        // Compute swap fee percentage
        // The starting price is NOT the last price. Instead, it is derived from lastBalances, 
        // stored before the first swap of the block. For example, if the last trader, who happens to be
        // the first trader of the block, pushed the price of USDC/ETH from 3000 to 3050, 
        // and the current trader pushes the price from 3050 to 3200 in the same block, 
        // thus the current trader's swap fee would be the swap fee calculated from 3000 to 3200,
        // minus the swap fee calculated calculated from from 3000 to 3050.
        if (lastBalanceOut > balanceOut) {
            return getSwapFeePercentageGivenExactOut(
                lastBalanceOut, 
                weightOut.divUp(weightIn), 
                lastBalanceOut - balanceOut,
                lastBalanceOut - balanceOut + amountOut
            );
        } else {
            return getSwapFeePercentageGivenExactOut(lastBalanceOut, weightOut.divUp(weightIn), 0, amountOut);
        }
    }

    /**
     * @notice Compute the `swapFeeAmount` of tokenIn in a swap, given the current balances and weights.
     * @dev `powerWithFees` is always greater than `powerWithoutFees`.
     * @param balanceIn The current balance of `tokenIn`
     * @param exponent The weight of `tokenIn` divided by the weight of `tokenOut`, rounded down
     * @param grossAmountIn The exact gross amount of `tokenIn`
     * @param lastAmountIn The exact last amount of `tokenIn`
     */
    function getSwapFeePercentageGivenExactIn(
        uint256 balanceIn,
        uint256 exponent,
        uint256 lastAmountIn,
        uint256 grossAmountIn
    ) internal pure returns (uint256) {
        /**********************************************************************************************
        // inGivenExactOutWithFees                                                                   //
        // aO = amountOut                                                                            //
        // bO = balanceOut                                                                           //
        // bI = balanceIn              /  /        bO - aO            \    (wO / wI)      \          //
        // aI = amountIn    aI = bI * |  | --------------------------  | ^            - 1  |         //
        // wI = weightIn               \  \     ( bO - aO * 2)        /                   /          //
        // wO = weightOut                                                                            //
        **********************************************************************************************/
        
        // grossSwapFee = inGivenExactOutWithFees(grossAmountIn) - inGivenExactOut(grossAmountIn)
        // lastSwapFee = inGivenExactOutWithFees(lastAmountIn) - inGivenExactOut(lastAmountIn)
        // netSwapFee = grossSwapFee - lastSwapFee

        // Amount in, so we round up overall.

        uint256 grossPowerWithFees = (balanceIn + grossAmountIn).divUp(balanceIn + grossAmountIn * 2).powUp(exponent);
        uint256 grossPowerWithoutFees = (balanceIn).divUp(balanceIn + grossAmountIn).powUp(exponent);
        if (lastAmountIn !=0) {
            uint256 lastPowerWithFees = (balanceIn + lastAmountIn).divUp(balanceIn + lastAmountIn * 2).powUp(exponent);
            uint256 lastPowerWithoutFees = (balanceIn).divUp(balanceIn + lastAmountIn).powUp(exponent);
            return exponent.mulDivUp(
                (balanceIn + grossAmountIn).mulDivUp(grossPowerWithFees - grossPowerWithoutFees, grossPowerWithFees)
                    - (balanceIn + lastAmountIn).mulDivUp(lastPowerWithFees - lastPowerWithoutFees, lastPowerWithFees),
                grossAmountIn - lastAmountIn
            );
        } else {
            return exponent.mulDivUp(
                (balanceIn + grossAmountIn).mulDivUp(grossPowerWithFees - grossPowerWithoutFees, grossPowerWithFees),
                grossAmountIn
            );
        }
    }

    /**
     * @notice Compute the `swapFeeAmount` of tokenIn in a swap, given the current balances and weights.
     * @dev `powerWithFees` is always greater than `powerWithoutFees`.
     * `grossPowerWithFees` restricts a trader from draining more than 50% of the `balanceOut`.
     * @param balanceOut The current balance of `tokenIn`
     * @param exponent The weight of `tokenOut` divided by the weight of `tokenIn`, rounded up
     * @param grossAmountOut The exact gross amount of `tokenOut`
     * @param lastAmountOut The exact last amount of `tokenOut`
     */
    function getSwapFeePercentageGivenExactOut(
        uint256 balanceOut,
        uint256 exponent,
        uint256 lastAmountOut,
        uint256 grossAmountOut
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
        
        // grossSwapFee = inGivenExactOutWithFees(grossAmountIn) - inGivenExactOut(grossAmountIn)
        // lastSwapFee = inGivenExactOutWithFees(lastAmountIn) - inGivenExactOut(lastAmountIn)
        // netSwapFee = grossSwapFee - lastSwapFee

        // Amount in, so we round up overall.

        uint256 grossPowerWithFees = (balanceOut - grossAmountOut).divUp(balanceOut - grossAmountOut * 2).powUp(exponent);
        uint256 grossPowerWithoutFees = (balanceOut).divUp(balanceOut - grossAmountOut).powUp(exponent);
        if (lastAmountOut !=0) {
            uint256 lastPowerWithFees = (balanceOut - lastAmountOut).divUp(balanceOut - lastAmountOut * 2).powUp(exponent);
            uint256 lastPowerWithoutFees = (balanceOut).divUp(balanceOut - lastAmountOut).powUp(exponent);
            return ((grossPowerWithFees - grossPowerWithoutFees) - (lastPowerWithFees - lastPowerWithoutFees)).divUp(
                grossPowerWithoutFees - lastPowerWithoutFees
            );
        } else {
            return (grossPowerWithFees - grossPowerWithoutFees).divUp(grossPowerWithFees - FixedPoint.ONE);
        }
    }
}