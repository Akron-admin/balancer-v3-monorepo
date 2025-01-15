// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library Akron5050PoolMath {
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
     * @param balanceOut The current balance of `tokenOut`
     * @param amountIn The exact amount of `tokenIn` (i.e., the amount given in an ExactIn swap)
     * @return amountOut The calculated amount of `tokenOut` returned in an ExactIn swap
     */
    function computeOutGivenExactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn
    ) internal pure returns (uint256 amountOut) {
        /**********************************************************************************************
        // outGivenExactIn                                                                           //
        // aO = amountOut                                                                            //
        // bO = balanceOut             /         bO * aI           \                                 //
        // bI = balanceIn       aO =  | --------------------------  |                                //
        // aI = amountIn               \     ( bI + aI * 2 )       /                                 //
        **********************************************************************************************/

        // Amount out, so we round down overall.

        // Cannot exceed maximum in ratio.
        if (amountIn > balanceIn.mulDown(_MAX_IN_RATIO)) {
            revert MaxInRatio();
        }

        return balanceOut.mulDown(balanceIn + amountIn).divDown(balanceIn + amountIn * 2);
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
        // bO = balanceOut             /         bI * aO           \                                 //
        // bI = balanceIn       aI =  | --------------------------  |                                //
        // aI = amountIn               \     ( bO - aO * 2)        /                                 //
        **********************************************************************************************/

        // Amount in, so we round up overall.

        // Cannot exceed maximum out ratio.
        if (amountOut > balanceOut.mulDown(_MAX_OUT_RATIO)) {
            revert MaxOutRatio();
        }

        return balanceIn.mulUp(amountOut).divUp(balanceOut - amountOut * 2);
    }

    /**
     * @notice Compute the `amountIn` of tokenIn in a swap, given the current balances and weights.
     * @param balanceIn The current balance of `tokenIn`
     * @param lastBalanceIn The last balance of `tokenIn`
     * @param balanceOut The current balance of `tokenOut`
     * @param lastBalanceOut The last balance of `tokenOut`
     * @param amountIn The exact amount of `tokenIn` (i.e., the amount given in an ExactIn swap)
     * @param exponent The weight of `tokenIn` divided by weight of `tokenOut`, rounded down
     * @return swapFeePercentage The calculated swap Fee Percentage of `tokenIn` returned in an ExactIn swap
     */
    function computeSwapFeePercentageGivenExactIn(
        uint256 balanceIn,
        uint256 lastBalanceIn,
        uint256 balanceOut,
        uint256 lastBalanceOut,
        uint256 amountIn
    ) internal pure returns (uint256) {
        if (balanceIn * lastBalanceOut > balanceOut * lastBalanceIn) {
            lastBalanceIn = (lastBalanceOut * balanceIn * balanceOut / lastBalanceIn)
                .powDown(uint256(50e16)) * lastBalanceIn / lastBalanceOut;
            uint256 lastAmountIn = balanceIn - lastBalanceIn;
            amountIn += lastAmountIn;
            uint256 grossPower = (lastBalanceIn + amountIn).divUp(lastBalanceIn + amountIn * 2);
            uint256 lastGrossPower = (lastBalanceIn + lastAmountIn).divUp(lastBalanceIn + lastAmountIn * 2);
            uint256 netPower = (grossPower - lastBalanceIn.divUp(lastBalanceIn + amountIn)) 
                - (lastGrossPower - lastBalanceIn.divUp(lastBalanceIn + lastAmountIn));
            return (netPower * (lastBalanceIn + amountIn)).divUp(grossPower * amountIn);
        } else {
            uint256 sqrt = Math.sqrt(lastBalanceOut * balanceIn * balanceOut / lastBalanceIn, Math.Rounding.Floor);
            balanceIn = sqrt * lastBalanceIn / lastBalanceOut;
            uint256 grossPower = (balanceIn + amountIn).divUp(balanceIn + amountIn * 2);
            return (((grossPower - balanceIn.divUp(balanceIn + amountIn))) * (balanceIn + amountIn))
                .divUp(grossPower * amountIn);
        }
    }





    /**
     * @notice Compute the `amountIn` of tokenIn in a swap, given the current balances and weights.
     * @param balanceIn The current balance of `tokenIn`
     * @param lastBalanceIn The last balance of `tokenIn`
     * @param balanceOut The current balance of `tokenOut`
     * @param lastBalanceOut The last balance of `tokenOut`
     * @param amountOut The exact amount of `tokenOut` (i.e., the amount given in an ExactOut swap)
     * @return swapFeePercentage The calculated swap Fee Percentage of `tokenIn` returned in an ExactOut swap
     */
    function computeSwapFeePercentageGivenExactOut(
        uint256 balanceIn,
        uint256 lastBalanceIn,
        uint256 balanceOut,
        uint256 lastBalanceOut,
        uint256 amountOut
    ) internal pure returns (uint256) {
        if (balanceIn * lastBalanceOut > balanceOut * lastBalanceIn) {        
            uint256 lastAmountOut;
            {
            uint256 sqrt = Math.sqrt(lastBalanceIn * balanceOut * balanceIn / lastBalanceOut, Math.Rounding.Ceil);
            lastAmountOut = sqrt * lastBalanceOut / lastBalanceIn - balanceOut;
            amountOut += lastAmountOut;
            balanceOut = sqrt * lastBalanceOut / lastBalanceIn;
            }
            uint256 grossPower = (balanceOut - amountOut).divUp(balanceOut - amountOut * 2);
            uint256 lastGrossPower = (balanceOut - lastAmountOut).divUp(balanceOut - lastAmountOut * 2);
            return 
                (
                    grossPower - balanceOut.divUp(balanceOut - amountOut) 
                        - (lastGrossPower - balanceOut.divUp(balanceOut - lastAmountOut))
                ).divUp(grossPower - lastGrossPower);            
        } else {
            uint256 sqrt = Math.sqrt(lastBalanceIn * balanceOut * balanceIn / lastBalanceOut, Math.Rounding.Ceil);
            balanceOut = sqrt * lastBalanceOut / lastBalanceIn;
            uint256 power = (balanceOut - amountOut).divUp(balanceOut - amountOut * 2);
            return (power - balanceOut.divUp(balanceOut - amountOut)).divUp(power - FixedPoint.ONE);
        }
    }



}
