// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.4;

import "./FixedPoint.sol";
import "./LogExpMath.sol";

library WeightedMath {
    using FixedPoint for uint256;

    /// @dev User Attempted to burn less BPT than allowed for a specific amountOut.
    error MinBPTInForTokenOut();

    /// @dev User attempted to mint more BPT than allowed for a specific amountIn.
    error MaxOutBptForTokenIn();

    /// @dev User attempted to extract a disproportionate amountOut of tokens from a pool.
    error MaxOutRatio();

    /// @dev User attempted to add a disproportionate amountIn of tokens to a pool.
    error MaxInRatio();

    /**
     * @dev Error thrown when the calculated invariant is zero, indicating an issue with the invariant calculation.
     * Most commonly, this happens when a token balance is zero.
     */
    error ZeroInvariant();

    // A minimum normalized weight imposes a maximum weight ratio. We need this due to limitations in the
    // implementation of the power function, as these ratios are often exponents.
    uint256 internal constant _MIN_WEIGHT = 0.01e18;

    // Pool limits that arise from limitations in the fixed point power function (and the imposed 1:100 maximum weight
    // ratio).

    // Swap limits: amounts swapped may not be larger than this percentage of the total balance.
    uint256 internal constant _MAX_IN_RATIO = 0.3e18;
    uint256 internal constant _MAX_OUT_RATIO = 0.3e18;

    // Invariant growth limit: non-proportional joins cannot cause the invariant to increase by more than this ratio.
    uint256 internal constant _MAX_INVARIANT_RATIO = 3e18;
    // Invariant shrink limit: non-proportional exits cannot cause the invariant to decrease by less than this ratio.
    uint256 internal constant _MIN_INVARIANT_RATIO = 0.7e18;

    // About swap fees on joins and exits:
    // Any join or exit that is not perfectly balanced (e.g. all single token joins or exits) is mathematically
    // equivalent to a perfectly balanced join or exit followed by a series of swaps. Since these swaps would charge
    // swap fees, it follows that (some) joins and exits should as well.
    // On these operations, we split the token amounts in 'taxable' and 'non-taxable' portions, where the 'taxable' part
    // is the one to which swap fees are applied.

    // Invariant is used to collect protocol swap fees by comparing its value between two times.
    // So we can round always to the same direction. It is also used to initiate the BPT amount
    // and, because there is a minimum BPT, we round down the invariant.
    function calculateInvariant(
        uint256[] memory normalizedWeights,
        uint256[] memory balances
    ) internal pure returns (uint256 invariant) {
        /**********************************************************************************************
        // invariant               _____                                                             //
        // wi = weight index i      | |      wi                                                      //
        // bi = balance index i     | |  bi ^   = i                                                  //
        // i = invariant                                                                             //
        **********************************************************************************************/

        invariant = FixedPoint.ONE;
        for (uint256 i = 0; i < normalizedWeights.length; i++) {
            invariant = invariant.mulDown(balances[i].powDown(normalizedWeights[i]));
        }

        if (invariant == 0) {
            revert ZeroInvariant();
        }
    }

    // Computes how many tokens can be taken out of a pool if `amountIn` are sent, given the
    // current balances and weights.
    function calcOutGivenIn(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountIn
    ) internal pure returns (uint256) {
        /**********************************************************************************************
        // outGivenIn                                                                                //
        // aO = amountOut                                                                            //
        // bO = balanceOut                                                                           //
        // bI = balanceIn              /      /            bI             \    (wI / wO) \           //
        // aI = amountIn    aO = bO * |  1 - | --------------------------  | ^            |          //
        // wI = weightIn               \      \       ( bI + aI )         /              /           //
        // wO = weightOut                                                                            //
        **********************************************************************************************/

        // Amount out, so we round down overall.

        // The multiplication rounds down, and the subtrahend (power) rounds up (so the base rounds up too).
        // Because bI / (bI + aI) <= 1, the exponent rounds down.

        // Cannot exceed maximum in ratio
        if (amountIn > balanceIn.mulDown(_MAX_IN_RATIO)) {
            revert MaxInRatio();
        }

        uint256 denominator = balanceIn + amountIn;
        uint256 base = balanceIn.divUp(denominator);
        uint256 exponent = weightIn.divDown(weightOut);
        uint256 power = base.powUp(exponent);

        return balanceOut.mulDown(power.complement());
    }

    // Computes how many tokens must be sent to a pool in order to take `amountOut`, given the
    // current balances and weights.
    function calcInGivenOut(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountOut
    ) internal pure returns (uint256) {
        /**********************************************************************************************
        // inGivenOut                                                                                //
        // aO = amountOut                                                                            //
        // bO = balanceOut                                                                           //
        // bI = balanceIn              /  /            bO             \    (wO / wI)      \          //
        // aI = amountIn    aI = bI * |  | --------------------------  | ^            - 1  |         //
        // wI = weightIn               \  \       ( bO - aO )         /                   /          //
        // wO = weightOut                                                                            //
        **********************************************************************************************/

        // Amount in, so we round up overall.

        // The multiplication rounds up, and the power rounds up (so the base rounds up too).
        // Because b0 / (b0 - a0) >= 1, the exponent rounds up.

        // Cannot exceed maximum out ratio
        if (amountOut > balanceOut.mulDown(_MAX_OUT_RATIO)) {
            revert MaxOutRatio();
        }

        uint256 base = balanceOut.divUp(balanceOut - amountOut);
        uint256 exponent = weightOut.divUp(weightIn);
        uint256 power = base.powUp(exponent);

        // Because the base is larger than one (and the power rounds up), the power should always be larger than one, so
        // the following subtraction should never revert.
        uint256 ratio = power - FixedPoint.ONE;

        return balanceIn.mulUp(ratio);
    }

    function calcBptOutGivenExactTokensIn(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsIn,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        // BPT out, so we round down overall.

        uint256[] memory balanceRatiosWithFee = new uint256[](amountsIn.length);

        uint256 invariantRatioWithFees = 0;
        for (uint256 i = 0; i < balances.length; i++) {
            balanceRatiosWithFee[i] = (balances[i] + amountsIn[i]).divDown(balances[i]);
            invariantRatioWithFees = invariantRatioWithFees + balanceRatiosWithFee[i].mulDown(normalizedWeights[i]);
        }

        uint256 invariantRatio = computeJoinExactTokensInInvariantRatio(
            balances,
            normalizedWeights,
            amountsIn,
            balanceRatiosWithFee,
            invariantRatioWithFees,
            swapFeePercentage
        );

        uint256 bptOut = (invariantRatio > FixedPoint.ONE)
            ? bptTotalSupply.mulDown(invariantRatio - FixedPoint.ONE)
            : 0;
        return bptOut;
    }

    function calcBptOutGivenExactTokenIn(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 amountIn,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        // BPT out, so we round down overall.

        uint256 amountInWithoutFee;
        {
            uint256 balanceRatioWithFee = (balance + amountIn).divDown(balance);

            // The use of `normalizedWeight.complement()` assumes that the sum of all weights equals FixedPoint.ONE.
            // This may not be the case when weights are stored in a denormalized format or during a gradual weight
            // change due rounding errors during normalization or interpolation. This will result in a small difference
            // between the output of this function and the equivalent `_calcBptOutGivenExactTokensIn` call.
            uint256 invariantRatioWithFees = balanceRatioWithFee.mulDown(normalizedWeight) +
                normalizedWeight.complement();

            if (balanceRatioWithFee > invariantRatioWithFees) {
                uint256 nonTaxableAmount = invariantRatioWithFees > FixedPoint.ONE
                    ? balance.mulDown(invariantRatioWithFees - FixedPoint.ONE)
                    : 0;
                uint256 taxableAmount = amountIn - nonTaxableAmount;
                uint256 swapFee = taxableAmount.mulUp(swapFeePercentage);

                amountInWithoutFee = nonTaxableAmount + taxableAmount - swapFee;
            } else {
                amountInWithoutFee = amountIn;
                // If a token's amount in is not being charged a swap fee then it might be zero.
                // In this case, it's clear that the sender should receive no BPT.
                if (amountInWithoutFee == 0) {
                    return 0;
                }
            }
        }

        uint256 balanceRatio = (balance + amountInWithoutFee).divDown(balance);

        uint256 invariantRatio = balanceRatio.powDown(normalizedWeight);

        uint256 bptOut = (invariantRatio > FixedPoint.ONE)
            ? bptTotalSupply.mulDown(invariantRatio - FixedPoint.ONE)
            : 0;
        return bptOut;
    }

    /// @dev Intermediate function to avoid stack-too-deep errors.
    function computeJoinExactTokensInInvariantRatio(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsIn,
        uint256[] memory balanceRatiosWithFee,
        uint256 invariantRatioWithFees,
        uint256 swapFeePercentage
    ) internal pure returns (uint256 invariantRatio) {
        // Swap fees are charged on all tokens that are being added in a larger proportion than the overall invariant
        // increase.
        invariantRatio = FixedPoint.ONE;

        for (uint256 i = 0; i < balances.length; i++) {
            uint256 amountInWithoutFee;

            if (balanceRatiosWithFee[i] > invariantRatioWithFees) {
                // invariantRatioWithFees might be less than FixedPoint.ONE in edge scenarios due to rounding error,
                // particularly if the weights don't exactly add up to 100%.
                uint256 nonTaxableAmount = invariantRatioWithFees > FixedPoint.ONE
                    ? balances[i].mulDown(invariantRatioWithFees - FixedPoint.ONE)
                    : 0;
                uint256 swapFee = (amountsIn[i] - nonTaxableAmount).mulUp(swapFeePercentage);
                amountInWithoutFee = amountsIn[i] - swapFee;
            } else {
                amountInWithoutFee = amountsIn[i];

                // If a token's amount in is not being charged a swap fee then it might be zero (e.g. when joining a
                // Pool with only a subset of tokens). In this case, `balanceRatio` will equal `FixedPoint.ONE`, and
                // the `invariantRatio` will not change at all. We therefore skip to the next iteration, avoiding
                // the costly `powDown` call.
                if (amountInWithoutFee == 0) {
                    continue;
                }
            }

            uint256 balanceRatio = (balances[i] + amountInWithoutFee).divDown(balances[i]);

            invariantRatio = invariantRatio.mulDown(balanceRatio.powDown(normalizedWeights[i]));
        }
    }

    function calcTokenInGivenExactBptOut(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 bptAmountOut,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        /******************************************************************************************
        // tokenInForExactBPTOut                                                                 //
        // a = amountIn                                                                          //
        // b = balance                      /  /    totalBPT + bptOut      \    (1 / w)       \  //
        // bptOut = bptAmountOut   a = b * |  | --------------------------  | ^          - 1  |  //
        // bpt = totalBPT                   \  \       totalBPT            /                  /  //
        // w = weight                                                                            //
        ******************************************************************************************/

        // Token in, so we round up overall.

        // Calculate the factor by which the invariant will increase after minting BPTAmountOut
        uint256 invariantRatio = (bptTotalSupply + bptAmountOut).divUp(bptTotalSupply);
        if (invariantRatio > _MAX_INVARIANT_RATIO) {
            revert MaxOutBptForTokenIn();
        }

        // Calculate by how much the token balance has to increase to match the invariantRatio
        uint256 balanceRatio = invariantRatio.powUp(FixedPoint.ONE.divUp(normalizedWeight));

        uint256 amountInWithoutFee = balance.mulUp(balanceRatio - FixedPoint.ONE);

        // We can now compute how much extra balance is being deposited and used in virtual swaps, and charge swap fees
        // accordingly.
        uint256 taxableAmount = amountInWithoutFee.mulUp(normalizedWeight.complement());
        uint256 nonTaxableAmount = amountInWithoutFee - taxableAmount;

        uint256 taxableAmountPlusFees = taxableAmount.divUp(swapFeePercentage.complement());

        return nonTaxableAmount + taxableAmountPlusFees;
    }

    function calcBptInGivenExactTokensOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsOut,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        // BPT in, so we round up overall.

        uint256[] memory balanceRatiosWithoutFee = new uint256[](amountsOut.length);
        uint256 invariantRatioWithoutFees = 0;
        for (uint256 i = 0; i < balances.length; i++) {
            balanceRatiosWithoutFee[i] = (balances[i] - amountsOut[i]).divUp(balances[i]);
            invariantRatioWithoutFees = (invariantRatioWithoutFees + balanceRatiosWithoutFee[i]).mulUp(
                normalizedWeights[i]
            );
        }

        uint256 invariantRatio = computeExitExactTokensOutInvariantRatio(
            balances,
            normalizedWeights,
            amountsOut,
            balanceRatiosWithoutFee,
            invariantRatioWithoutFees,
            swapFeePercentage
        );

        return bptTotalSupply.mulUp(invariantRatio.complement());
    }

    function calcBptInGivenExactTokenOut(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 amountOut,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        // BPT in, so we round up overall.

        uint256 balanceRatioWithoutFee = (balance - amountOut).divUp(balance);

        uint256 invariantRatioWithoutFees = balanceRatioWithoutFee.mulUp(normalizedWeight) +
            normalizedWeight.complement();

        uint256 amountOutWithFee;
        if (invariantRatioWithoutFees > balanceRatioWithoutFee) {
            // Swap fees are typically charged on 'token in', but there is no 'token in' here, so we apply it to
            // 'token out'. This results in slightly larger price impact.

            uint256 nonTaxableAmount = balance.mulDown(invariantRatioWithoutFees.complement());
            uint256 taxableAmount = amountOut - nonTaxableAmount;
            uint256 taxableAmountPlusFees = taxableAmount.divUp(swapFeePercentage.complement());

            amountOutWithFee = nonTaxableAmount + taxableAmountPlusFees;
        } else {
            amountOutWithFee = amountOut;
            // If a token's amount out is not being charged a swap fee then it might be zero.
            // In this case, it's clear that the sender should not send any BPT.
            if (amountOutWithFee == 0) {
                return 0;
            }
        }

        uint256 balanceRatio = (balance - amountOutWithFee).divDown(balance);

        uint256 invariantRatio = balanceRatio.powDown(normalizedWeight);

        return bptTotalSupply.mulUp(invariantRatio.complement());
    }

    /// @dev Intermediate function to avoid stack-too-deep errors.
    function computeExitExactTokensOutInvariantRatio(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsOut,
        uint256[] memory balanceRatiosWithoutFee,
        uint256 invariantRatioWithoutFees,
        uint256 swapFeePercentage
    ) internal pure returns (uint256 invariantRatio) {
        invariantRatio = FixedPoint.ONE;

        for (uint256 i = 0; i < balances.length; i++) {
            // Swap fees are typically charged on 'token in', but there is no 'token in' here, so we apply it to
            // 'token out'. This results in slightly larger price impact.

            uint256 amountOutWithFee;
            if (invariantRatioWithoutFees > balanceRatiosWithoutFee[i]) {
                uint256 nonTaxableAmount = balances[i].mulDown(invariantRatioWithoutFees.complement());
                uint256 taxableAmount = amountsOut[i] - nonTaxableAmount;
                uint256 taxableAmountPlusFees = taxableAmount.divUp(swapFeePercentage.complement());

                amountOutWithFee = nonTaxableAmount + taxableAmountPlusFees;
            } else {
                amountOutWithFee = amountsOut[i];
                // If a token's amount out is not being charged a swap fee then it might be zero (e.g. when exiting a
                // Pool with only a subset of tokens). In this case, `balanceRatio` will equal `FixedPoint.ONE`, and
                // the `invariantRatio` will not change at all. We therefore skip to the next iteration, avoiding
                // the costly `powDown` call.
                if (amountOutWithFee == 0) {
                    continue;
                }
            }

            uint256 balanceRatio = (balances[i] - amountOutWithFee).divDown(balances[i]);

            invariantRatio = invariantRatio.mulDown(balanceRatio.powDown(normalizedWeights[i]));
        }
    }

    function calcTokenOutGivenExactBptIn(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 bptAmountIn,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        /*****************************************************************************************
        // exactBPTInForTokenOut                                                                //
        // a = amountOut                                                                        //
        // b = balance                     /      /    totalBPT - bptIn       \    (1 / w)  \   //
        // bptIn = bptAmountIn    a = b * |  1 - | --------------------------  | ^           |  //
        // bpt = totalBPT                  \      \       totalBPT            /             /   //
        // w = weight                                                                           //
        *****************************************************************************************/

        // Token out, so we round down overall. The multiplication rounds down, but the power rounds up (so the base
        // rounds up). Because (totalBPT - bptIn) / totalBPT <= 1, the exponent rounds down.

        // Calculate the factor by which the invariant will decrease after burning BPTAmountIn
        uint256 invariantRatio = (bptTotalSupply - bptAmountIn).divUp(bptTotalSupply);
        if (invariantRatio < _MIN_INVARIANT_RATIO) {
            revert MinBPTInForTokenOut();
        }

        // Calculate by how much the token balance has to decrease to match invariantRatio
        uint256 balanceRatio = invariantRatio.powUp(FixedPoint.ONE.divDown(normalizedWeight));

        // Because of rounding up, balanceRatio can be greater than one. Using complement prevents reverts.
        uint256 amountOutWithoutFee = balance.mulDown(balanceRatio.complement());

        // We can now compute how much excess balance is being withdrawn as a result of the virtual swaps, which result
        // in swap fees.

        // Swap fees are typically charged on 'token in', but there is no 'token in' here, so we apply it
        // to 'token out'. This results in slightly larger price impact. Fees are rounded up.
        uint256 taxableAmount = amountOutWithoutFee.mulUp(normalizedWeight.complement());
        uint256 nonTaxableAmount = amountOutWithoutFee - taxableAmount;
        uint256 taxableAmountMinusFees = taxableAmount.mulUp(swapFeePercentage.complement());

        return nonTaxableAmount + taxableAmountMinusFees;
    }

    /**
     * @dev Calculate the amount of BPT which should be minted when adding a new token to the Pool.
     *
     * Note that normalizedWeight is set that it corresponds to the desired weight of this token *after* adding it.
     * i.e. For a two token 50:50 pool which we want to turn into a 33:33:33 pool, we use a normalized weight of 33%.
     *
     * @param totalSupply - the total supply of the Pool's BPT
     * @param normalizedWeight - the normalized weight of the token to be added (normalized relative to final weights)
     */
    function calcBptOutAddToken(uint256 totalSupply, uint256 normalizedWeight) internal pure returns (uint256) {
        // The amount of BPT which is equivalent to the token being added may be calculated by the growth in the
        // sum of the token weights, i.e. if we add a token which will make up 50% of the pool then we should receive
        // 50% of the new supply of BPT.
        //
        // The growth in the total weight of the pool can be easily calculated by:
        //
        // weightSumRatio = totalWeight / (totalWeight - newTokenWeight)
        //
        // As we're working with normalized weights `totalWeight` is equal to 1.

        uint256 weightSumRatio = FixedPoint.ONE.divDown(FixedPoint.ONE - normalizedWeight);

        // The amount of BPT to mint is then simply:
        //
        // toMint = totalSupply * (weightSumRatio - 1)

        return totalSupply.mulDown(weightSumRatio - FixedPoint.ONE);
    }
}