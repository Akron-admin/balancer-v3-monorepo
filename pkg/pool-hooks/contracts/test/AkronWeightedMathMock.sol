// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { AkronWeightedMath } from "../utils/AkronWeightedMath.sol";

contract AkronWeightedMathMock {
    function computeSwapFeePercentageGivenExactIn(
        uint256 balanceIn, 
        uint256 exponent, 
        uint256 amountIn
    ) public pure returns (uint256) {
        return AkronWeightedMath.computeSwapFeePercentageGivenExactIn(balanceIn, exponent, amountIn);
    }

    function computeSwapFeePercentageGivenExactOut(
        uint256 balanceOut,
        uint256 exponent,
        uint256 amountOut
    ) public pure returns (uint256) {
        return AkronWeightedMath.computeSwapFeePercentageGivenExactOut(balanceOut, exponent, amountOut)  ;
    }
}
