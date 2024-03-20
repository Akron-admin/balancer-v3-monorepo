// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.4;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultExtension } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultExtension.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IRouter } from "@balancer-labs/v3-interfaces/contracts/vault/IRouter.sol";
import { IWETH } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { EnumerableSet } from "@balancer-labs/v3-solidity-utils/contracts/openzeppelin/EnumerableSet.sol";
import { RevertCodec } from "@balancer-labs/v3-solidity-utils/contracts/helpers/RevertCodec.sol";

contract PriceImpact is ReentrancyGuard {
    using FixedPoint for uint256;

    error SwapDeadline();

    IVault private immutable _vault;

    modifier onlyVault() {
        if (msg.sender != address(_vault)) {
            revert IVaultErrors.SenderIsNotVault(msg.sender);
        }
        _;
    }

    constructor(IVault vault) {
        _vault = vault;
    }

    /*******************************************************************************
                                Price Impact
    *******************************************************************************/

    function priceImpactForAddLiquidityUnbalanced(
        address pool,
        uint256[] memory exactAmountsIn
    ) external returns (uint256 priceImpact) {
        // query addLiquidityUnbalanced
        uint256 bptAmountOut = _queryAddLiquidityUnbalanced(pool, exactAmountsIn, 0, "");
        // query removeLiquidityProportional
        uint256[] memory proportionalAmountsOut = _queryRemoveLiquidityProportional(
            pool,
            bptAmountOut,
            new uint256[](exactAmountsIn.length),
            ""
        );
        // get deltas between exactAmountsIn and proportionalAmountsOut
        int256[] memory deltas = new int256[](exactAmountsIn.length);
        for (uint256 i = 0; i < exactAmountsIn.length; i++) {
            deltas[i] = int(proportionalAmountsOut[i]) - int(exactAmountsIn[i]);
        }
        // query add liquidity for each delta, so we know how unbalanced each amount in is in terms of BPT
        int256[] memory deltaBPTs = new int256[](exactAmountsIn.length);
        for (uint256 i = 0; i < exactAmountsIn.length; i++) {
            deltaBPTs[i] = _queryAddLiquidityForTokenDelta(pool, i, deltas);
        }
        // zero out deltas leaving only a remaining delta within a single token
        uint256 remaininDeltaIndex = _zeroOutDeltas(pool, deltas, deltaBPTs);
        // calculate price impact ABA with remaining delta and its respective exactAmountIn
        // remaining delta is always negative, so by multiplying by -1 we get a positive number
        uint256 delta = uint(deltas[remaininDeltaIndex] * -1);
        return delta.divDown(exactAmountsIn[remaininDeltaIndex]) / 2;
    }

    /*******************************************************************************
                                    Helpers
    *******************************************************************************/

    function _queryAddLiquidityForTokenDelta(
        address pool,
        uint256 tokenIndex,
        int256[] memory deltas
    ) internal returns (int256 deltaBPT) {
        uint256[] memory zerosWithSingleDelta = new uint256[](deltas.length);
        if (deltas[tokenIndex] == 0) {
            return 0;
        } else if (deltas[tokenIndex] > 0) {
            zerosWithSingleDelta[tokenIndex] = uint(deltas[tokenIndex]);
            return int(_queryAddLiquidityUnbalanced(pool, zerosWithSingleDelta, 0, ""));
        } else {
            zerosWithSingleDelta[tokenIndex] = uint(deltas[tokenIndex] * -1);
            return int(_queryAddLiquidityUnbalanced(pool, zerosWithSingleDelta, 0, "")) * -1;
        }
    }

    function _zeroOutDeltas(
        address pool,
        int256[] memory deltas,
        int256[] memory deltaBPTs
    ) internal returns (uint256) {
        uint256 minNegativeDeltaIndex = 0;
        IERC20[] memory poolTokens = _vault.getPoolTokens(pool);

        for (uint256 i = 0; i < deltas.length - 1; i++) {
            // get minPositiveDeltaIndex and maxNegativeDeltaIndex
            uint256 minPositiveDeltaIndex = _minPositiveIndex(deltaBPTs);
            minNegativeDeltaIndex = _maxNegativeIndex(deltaBPTs);

            uint256 givenTokenIndex;
            uint256 resultTokenIndex;
            uint256 resultAmount;

            if (deltaBPTs[minPositiveDeltaIndex] < deltaBPTs[minNegativeDeltaIndex] * -1) {
                givenTokenIndex = minPositiveDeltaIndex;
                resultTokenIndex = minNegativeDeltaIndex;
                resultAmount = _querySwapSingleTokenExactIn(
                    pool,
                    poolTokens[givenTokenIndex],
                    poolTokens[resultTokenIndex],
                    uint(deltas[givenTokenIndex]),
                    ""
                );
            } else {
                givenTokenIndex = minNegativeDeltaIndex;
                resultTokenIndex = minPositiveDeltaIndex;
                resultAmount = _querySwapSingleTokenExactOut(
                    pool,
                    poolTokens[resultTokenIndex],
                    poolTokens[givenTokenIndex],
                    uint(deltas[givenTokenIndex] * -1),
                    ""
                );
            }

            // Update deltas and deltaBPTs
            deltas[givenTokenIndex] = 0;
            deltaBPTs[givenTokenIndex] = 0;
            deltas[resultTokenIndex] += int(resultAmount);
            deltaBPTs[resultTokenIndex] = _queryAddLiquidityForTokenDelta(pool, resultTokenIndex, deltas);
        }

        return minNegativeDeltaIndex;
    }

    // returns the index of the smallest positive integer in an array - i.e. [3, 2, -2, -3] returns 1
    function _minPositiveIndex(int256[] memory array) internal pure returns (uint256 index) {
        int256 min = type(int256).max;
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] > 0 && array[i] < min) {
                min = array[i];
                index = i;
            }
        }
    }

    // returns the index of the biggest negative integer in an array - i.e. [3, 1, -2, -3] returns 2
    function _maxNegativeIndex(int256[] memory array) internal pure returns (uint256 index) {
        int256 max = type(int256).min;
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] < 0 && array[i] > max) {
                max = array[i];
                index = i;
            }
        }
    }

    /*******************************************************************************
                                    Pools
    *******************************************************************************/

    function _swapHook(
        IRouter.SwapSingleTokenHookParams calldata params
    ) internal returns (uint256 amountCalculated, uint256 amountIn, uint256 amountOut) {
        // The deadline is timestamp-based: it should not be relied upon for sub-minute accuracy.
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > params.deadline) {
            revert SwapDeadline();
        }

        (amountCalculated, amountIn, amountOut) = _vault.swap(
            SwapParams({
                kind: params.kind,
                pool: params.pool,
                tokenIn: params.tokenIn,
                tokenOut: params.tokenOut,
                amountGivenRaw: params.amountGiven,
                limitRaw: params.limit,
                userData: params.userData
            })
        );
    }

    /*******************************************************************************
                                    Queries
    *******************************************************************************/

    function querySwapSingleTokenExactIn(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountIn,
        bytes calldata userData
    ) external returns (uint256 amountCalculated) {
        return _querySwapSingleTokenExactIn(pool, tokenIn, tokenOut, exactAmountIn, userData);
    }

    function _querySwapSingleTokenExactIn(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountIn,
        bytes memory userData
    ) internal returns (uint256 amountCalculated) {
        try
            _vault.quoteAndRevert(
                abi.encodeWithSelector(
                    PriceImpact.querySwapHook.selector,
                    IRouter.SwapSingleTokenHookParams({
                        sender: msg.sender,
                        kind: SwapKind.EXACT_IN,
                        pool: pool,
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        amountGiven: exactAmountIn,
                        limit: 0,
                        deadline: type(uint256).max,
                        wethIsEth: false,
                        userData: userData
                    })
                )
            )
        {
            revert("Unexpected success");
        } catch (bytes memory result) {
            amountCalculated = abi.decode(RevertCodec.catchEncodedResult(result), (uint256));
            return amountCalculated;
        }
    }

    function querySwapSingleTokenExactOut(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountOut,
        bytes calldata userData
    ) external returns (uint256 amountCalculated) {
        return _querySwapSingleTokenExactOut(pool, tokenIn, tokenOut, exactAmountOut, userData);
    }

    function _querySwapSingleTokenExactOut(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountOut,
        bytes memory userData
    ) internal returns (uint256 amountCalculated) {
        try
            _vault.quoteAndRevert(
                abi.encodeWithSelector(
                    PriceImpact.querySwapHook.selector,
                    IRouter.SwapSingleTokenHookParams({
                        sender: msg.sender,
                        kind: SwapKind.EXACT_OUT,
                        pool: pool,
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        amountGiven: exactAmountOut,
                        limit: type(uint256).max,
                        deadline: type(uint256).max,
                        wethIsEth: false,
                        userData: userData
                    })
                )
            )
        {
            revert("Unexpected success");
        } catch (bytes memory result) {
            amountCalculated = abi.decode(RevertCodec.catchEncodedResult(result), (uint256));
            return amountCalculated;
        }
    }

    /**
     * @notice Hook for swap queries.
     * @dev Can only be called by the Vault. Also handles native ETH.
     * @param params Swap parameters (see IRouter for struct definition)
     * @return Token amount calculated by the pool math (e.g., amountOut for a exact in swap)
     */
    function querySwapHook(
        IRouter.SwapSingleTokenHookParams calldata params
    ) external payable nonReentrant onlyVault returns (uint256) {
        (uint256 amountCalculated, , ) = _swapHook(params);

        return amountCalculated;
    }

    function queryAddLiquidityUnbalanced(
        address pool,
        uint256[] memory exactAmountsIn,
        uint256 minBptAmountOut,
        bytes memory userData
    ) external returns (uint256 bptAmountOut) {
        return _queryAddLiquidityUnbalanced(pool, exactAmountsIn, minBptAmountOut, userData);
    }

    function _queryAddLiquidityUnbalanced(
        address pool,
        uint256[] memory exactAmountsIn,
        uint256 minBptAmountOut,
        bytes memory userData
    ) internal returns (uint256 bptAmountOut) {
        try
            _vault.quoteAndRevert(
                abi.encodeWithSelector(
                    PriceImpact.queryAddLiquidityHook.selector,
                    IRouter.AddLiquidityHookParams({
                        // we use router as a sender to simplify basic query functions
                        // but it is possible to add liquidity to any recipient
                        sender: address(this),
                        pool: pool,
                        maxAmountsIn: exactAmountsIn,
                        minBptAmountOut: minBptAmountOut,
                        kind: AddLiquidityKind.UNBALANCED,
                        wethIsEth: false,
                        userData: userData
                    })
                )
            )
        {
            revert("Unexpected success");
        } catch (bytes memory result) {
            (, bptAmountOut, ) = abi.decode(RevertCodec.catchEncodedResult(result), (uint256[], uint256, bytes));
            return bptAmountOut;
        }
    }

    /**
     * @notice Hook for add liquidity queries.
     * @dev Can only be called by the Vault.
     * @param params Add liquidity parameters (see IRouter for struct definition)
     * @return amountsIn Actual token amounts in required as inputs
     * @return bptAmountOut Expected pool tokens to be minted
     * @return returnData Arbitrary (optional) data with encoded response from the pool
     */
    function queryAddLiquidityHook(
        IRouter.AddLiquidityHookParams calldata params
    )
        external
        payable
        nonReentrant
        onlyVault
        returns (uint256[] memory amountsIn, uint256 bptAmountOut, bytes memory returnData)
    {
        (amountsIn, bptAmountOut, returnData) = _vault.addLiquidity(
            AddLiquidityParams({
                pool: params.pool,
                to: params.sender,
                maxAmountsIn: params.maxAmountsIn,
                minBptAmountOut: params.minBptAmountOut,
                kind: params.kind,
                userData: params.userData
            })
        );
    }

    function queryRemoveLiquidityProportional(
        address pool,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bytes memory userData
    ) external returns (uint256[] memory amountsOut) {
        return _queryRemoveLiquidityProportional(pool, exactBptAmountIn, minAmountsOut, userData);
    }

    function _queryRemoveLiquidityProportional(
        address pool,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bytes memory userData
    ) internal returns (uint256[] memory amountsOut) {
        try
            _vault.quoteAndRevert(
                abi.encodeWithSelector(
                    PriceImpact.queryRemoveLiquidityHook.selector,
                    IRouter.RemoveLiquidityHookParams({
                        // We use router as a sender to simplify basic query functions
                        // but it is possible to remove liquidity from any sender
                        sender: address(this),
                        pool: pool,
                        minAmountsOut: minAmountsOut,
                        maxBptAmountIn: exactBptAmountIn,
                        kind: RemoveLiquidityKind.PROPORTIONAL,
                        wethIsEth: false,
                        userData: userData
                    })
                )
            )
        {
            revert("Unexpected success");
        } catch (bytes memory result) {
            (, amountsOut, ) = abi.decode(RevertCodec.catchEncodedResult(result), (uint256, uint256[], bytes));
            return amountsOut;
        }
    }

    /**
     * @notice Hook for remove liquidity queries.
     * @dev Can only be called by the Vault.
     * @param params Remove liquidity parameters (see IRouter for struct definition)
     * @return bptAmountIn Pool token amount to be burned for the output tokens
     * @return amountsOut Expected token amounts to be transferred to the sender
     * @return returnData Arbitrary (optional) data with encoded response from the pool
     */
    function queryRemoveLiquidityHook(
        IRouter.RemoveLiquidityHookParams calldata params
    )
        external
        nonReentrant
        onlyVault
        returns (uint256 bptAmountIn, uint256[] memory amountsOut, bytes memory returnData)
    {
        return
            _vault.removeLiquidity(
                RemoveLiquidityParams({
                    pool: params.pool,
                    from: params.sender,
                    maxBptAmountIn: params.maxBptAmountIn,
                    minAmountsOut: params.minAmountsOut,
                    kind: params.kind,
                    userData: params.userData
                })
            );
    }
}
