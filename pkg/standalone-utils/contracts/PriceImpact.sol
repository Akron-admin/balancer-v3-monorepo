// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.4;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IRouter } from "@balancer-labs/v3-interfaces/contracts/vault/IRouter.sol";
import { IWETH } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { EnumerableSet } from "@balancer-labs/v3-solidity-utils/contracts/openzeppelin/EnumerableSet.sol";

contract PriceImpact {
    using Address for address payable;
    using EnumerableSet for EnumerableSet.AddressSet;
    using FixedPoint for int256;

    IVault private immutable _vault;

    // solhint-disable-next-line var-name-mixedcase
    IWETH private immutable _weth;

    // Transient storage used to track tokens and amount flowing in and out within a batch swap.
    // Set of input tokens involved in a batch swap.
    EnumerableSet.AddressSet private _currentSwapTokensIn;
    // Set of output tokens involved in a batch swap.
    EnumerableSet.AddressSet private _currentSwapTokensOut;
    // token in -> amount: tracks token in amounts within a batch swap.
    mapping(address => uint256) private _currentSwapTokenInAmounts;
    // token out -> amount: tracks token out amounts within a batch swap.
    mapping(address => uint256) private _currentSwapTokenOutAmounts;

    modifier onlyVault() {
        if (msg.sender != address(_vault)) {
            revert IVaultErrors.SenderIsNotVault(msg.sender);
        }
        _;
    }

    constructor(IVault vault, IWETH weth) {
        _vault = vault;
        _weth = weth;
        weth.approve(address(_vault), type(uint256).max);
    }

    /*******************************************************************************
                                Price Impact
    *******************************************************************************/

    function priceImpactForAddLiquidityUnbalanced(
        address pool,
        uint256[] exactAmountsIn
    ) external returns (uint256 priceImpact) {
        // query addLiquidityUnbalanced
        uint256 bptAmountOut = queryAddLiquidityUnbalanced(pool, exactAmountsIn, 0, new bytes(0));
        // query removeLiquidityProportional
        uint256[] proportionalAmountsOut = queryRemoveLiquidityProportional(
            pool,
            bptAmountOut,
            new uint256[](exactAmountsIn.length),
            userData
        );
        // get deltas between exactAmountsIn and proportionalAmountsOut
        int256[] deltas = new uint256[](exactAmountsIn.length);
        for (uint256 i = 0; i < exactAmountsIn.length; i++) {
            deltas[i] = proportionalAmountsOut[i] - exactAmountsIn[i];
        }
        // query add liquidity for each delta, so we know how unbalanced each amount in is in terms of BPT
        int256[] deltaBPTs = new int256[](exactAmountsIn.length);
        for (uint256 i = 0; i < exactAmountsIn.length; i++) {
            deltaBPTs[i] = queryAddLiquidityForTokenDelta(pool, i, deltas, deltaBPTs);
        }
        // zero out deltas leaving only a remaining delta within a single token
        uint256 remaininDeltaIndex = zeroOutDeltas(pool, deltas, deltaBPTs);
        // calculate price impact ABA with remaining delta and its respective exactAmountIn
        return deltas[remaininDeltaIndex].divDown(exactAmountsIn[remaininDeltaIndex]) / 2;
    }

    /*******************************************************************************
                                    Helpers
    *******************************************************************************/

    function queryAddLiquidityForTokenDelta(
        address pool,
        uint256 tokenIndex,
        int256 deltas,
        int256 deltaBPTs
    ) internal returns (int256 deltaBPT) {
        uint256[] zerosWithSingleDelta = new uint256[](deltas.length);
        if (deltaBPTs[tokenIndex] == 0) {
            return 0;
        } else if (deltaBPTs[tokenIndex] > 0) {
            zerosWithSingleDelta[tokenIndex] = deltas[tokenIndex];
            return queryAddLiquidityUnbalanced(pool, zerosWithSingleDelta, 0, new bytes(0));
        } else {
            zerosWithSingleDelta[tokenIndex] = deltas[tokenIndex] * -1;
            return queryAddLiquidityUnbalanced(pool, zerosWithSingleDelta, 0, new bytes(0));
        }
    }

    function zeroOutDeltas(address pool, int256[] deltas, int256[] deltaBPTs) internal returns (uint256) {
        uint256 minNegativeDeltaIndex = 0;

        for (uint256 i = 0; i < deltas.length - 1; i++) {
            // get minPositiveDeltaIndex and maxNegativeDeltaIndex
            uint256 minPositiveDeltaIndex = minPositiveIndex(deltaBPTs);
            uint256 minNegativeDeltaIndex = maxNegativeIndex(deltaBPTs);

            uint256 givenTokenIndex;
            uint256 resultTokenIndex;
            uint256 resultAmount;

            if (deltaBPTs[minPositiveDeltaIndex] < deltaBPTs[minNegativeDeltaIndex] * -1) {
                givenTokenIndex = minPositiveDeltaIndex;
                resultTokenIndex = minNegativeDeltaIndex;
                resultAmount = querySwapSingleTokenExactIn(
                    pool,
                    IERC20(_vault.getPoolToken(pool, givenTokenIndex)),
                    IERC20(_vault.getPoolToken(pool, resultTokenIndex)),
                    deltas[givenTokenIndex],
                    new bytes(0)
                );
            } else {
                givenTokenIndex = minNegativeDeltaIndex;
                resultTokenIndex = minPositiveDeltaIndex;
                resultAmount = querySwapSingleTokenExactOut(
                    pool,
                    IERC20(_vault.getPoolToken(pool, resultTokenIndex)),
                    IERC20(_vault.getPoolToken(pool, givenTokenIndex)),
                    deltas[givenTokenIndex] * -1,
                    new bytes(0)
                );
            }

            // Update deltas and deltaBPTs
            deltas[givenTokenIndex] = 0;
            deltaBPTs[givenTokenIndex] = 0;
            deltas[resultTokenIndex] += resultAmount;
            deltaBPTs[resultTokenIndex] = queryAddLiquidityForTokenDelta(pool, resultTokenIndex, deltas, deltaBPTs);
        }

        return minNegativeDeltaIndex;
    }

    // returns the index of the smallest positive integer in an array - i.e. [3, 2, -2, -3] returns 1
    function minPositiveIndex(int256[] memory array) internal returns (uint256 index) {
        int256 min = type(int256).max;
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] > 0 && array[i] < min) {
                min = array[i];
                index = i;
            }
        }
    }

    // returns the index of the biggest negative integer in an array - i.e. [3, 1, -2, -3] returns 2
    function maxNegativeIndex(int256[] memory array) internal returns (uint256 index) {
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
        SwapSingleTokenHookParams calldata params
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

    /// @inheritdoc IRouter
    function querySwapSingleTokenExactIn(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountIn,
        bytes calldata userData
    ) external returns (uint256 amountCalculated) {
        return
            abi.decode(
                _vault.quote(
                    abi.encodeWithSelector(
                        Router.querySwapHook.selector,
                        SwapSingleTokenHookParams({
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
                ),
                (uint256)
            );
    }

    /// @inheritdoc IRouter
    function querySwapSingleTokenExactOut(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountOut,
        bytes calldata userData
    ) external returns (uint256 amountCalculated) {
        return
            abi.decode(
                _vault.quote(
                    abi.encodeWithSelector(
                        Router.querySwapHook.selector,
                        SwapSingleTokenHookParams({
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
                ),
                (uint256)
            );
    }

    /**
     * @notice Hook for swap queries.
     * @dev Can only be called by the Vault. Also handles native ETH.
     * @param params Swap parameters (see IRouter for struct definition)
     * @return Token amount calculated by the pool math (e.g., amountOut for a exact in swap)
     */
    function querySwapHook(
        SwapSingleTokenHookParams calldata params
    ) external payable nonReentrant onlyVault returns (uint256) {
        (uint256 amountCalculated, , ) = _swapHook(params);

        return amountCalculated;
    }

    /// @inheritdoc IRouter
    function queryAddLiquidityUnbalanced(
        address pool,
        uint256[] memory exactAmountsIn,
        uint256 minBptAmountOut,
        bytes memory userData
    ) external returns (uint256 bptAmountOut) {
        (, bptAmountOut, ) = abi.decode(
            _vault.quote(
                abi.encodeWithSelector(
                    Router.queryAddLiquidityHook.selector,
                    AddLiquidityHookParams({
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
            ),
            (uint256[], uint256, bytes)
        );
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
        AddLiquidityHookParams calldata params
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

    /// @inheritdoc IRouter
    function queryRemoveLiquidityProportional(
        address pool,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bytes memory userData
    ) external returns (uint256[] memory amountsOut) {
        (, amountsOut, ) = abi.decode(
            _vault.quote(
                abi.encodeWithSelector(
                    Router.queryRemoveLiquidityHook.selector,
                    RemoveLiquidityHookParams({
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
            ),
            (uint256, uint256[], bytes)
        );
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
        RemoveLiquidityHookParams calldata params
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