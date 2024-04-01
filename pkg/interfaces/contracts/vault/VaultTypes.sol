// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IRateProvider } from "./IRateProvider.sol";

/// @dev Represents a pool's hooks.
struct PoolHooks {
    bool shouldCallBeforeInitialize;
    bool shouldCallAfterInitialize;
    bool shouldCallBeforeSwap;
    bool shouldCallAfterSwap;
    bool shouldCallBeforeAddLiquidity;
    bool shouldCallAfterAddLiquidity;
    bool shouldCallBeforeRemoveLiquidity;
    bool shouldCallAfterRemoveLiquidity;
}

struct LiquidityManagement {
    bool supportsAddLiquidityCustom;
    bool supportsRemoveLiquidityCustom;
}

/// @dev Represents a pool's configuration, including hooks.
struct PoolConfig {
    PoolHooks hooks;
    LiquidityManagement liquidityManagement;
    uint256 staticSwapFeePercentage;
    uint256 tokenDecimalDiffs;
    uint256 pauseWindowEndTime;
    bool isPoolRegistered;
    bool isPoolInitialized;
    bool isPoolPaused;
    bool isPoolInRecoveryMode;
    bool hasDynamicSwapFee;
}

/**
 * @dev Represents the Vault's configuration.
 * @param protocolSwapFeePercentage Charged whenever a swap occurs, as a percentage of the fee charged by the Pool.
 * We allow 0% swap fee.
 * @param protocolYieldFeePercentage Charged on all pool operations for yield-bearing tokens.
 * @param isQueryDisabled If set to true, disables query functionality of the Vault. Can be modified only by
 * governance.
 * @param isVaultPaused If set to true, Swaps and Add/Remove Liquidity operations are halted
 */
struct VaultState {
    uint256 protocolSwapFeePercentage;
    uint256 protocolYieldFeePercentage;
    bool isQueryDisabled;
    bool isVaultPaused;
}

/**
 * @dev Token types supported by the Vault. In general, pools may contain any combination of these tokens.
 * STANDARD tokens (e.g., BAL, WETH) have no rate provider.
 * WITH_RATE tokens (e.g., wstETH) require a rate provider. These may be tokens like wstETH, which need to be wrapped
 * because the underlying stETH token is rebasing, and such tokens are unsupported by the Vault. They may also be
 * tokens like sEUR, which track an underlying asset, but are not yield-bearing. Finally, this encompasses
 * yield-bearing ERC4626 tokens, which can be used with ERC4626BufferPools to facilitate swaps without requiring
 * wrapping or unwrapping in most cases. The `paysYieldFees` flag can be used to indicate whether a token is
 * yield-bearing (e.g., waDAI), not yield-bearing (e.g., sEUR), or yield-bearing but exempt from fees (e.g., in
 * certain nested pools, where protocol yield fees are charged elsewhere).
 *
 * NB: STANDARD must always be the first enum element, so that newly initialized data structures default to Standard.
 */
enum TokenType {
    STANDARD,
    WITH_RATE
}

/**
 * @dev Encapsulate the data required for the Vault to support a token of the given type.
 * For STANDARD tokens, the rate provider address must be 0, and paysYieldFees must be false.
 * All WITH_RATE tokens need a rate provider, and may or may not be yield-bearing.
 *
 * @param token The token address
 * @param tokenType The token type (see the enum for supported types)
 * @param rateProvider The rate provider for a token (see further documentation above)
 * @param paysYieldFees Flag indicating whether yield fees should be charged on this token
 */
struct TokenConfig {
    IERC20 token;
    TokenType tokenType;
    IRateProvider rateProvider;
    bool paysYieldFees;
}

struct PoolData {
    PoolConfig poolConfig;
    TokenConfig[] tokenConfig;
    uint256[] balancesRaw;
    uint256[] balancesLiveScaled18;
    uint256[] tokenRates;
    uint256[] decimalScalingFactors;
}

enum Rounding {
    ROUND_UP,
    ROUND_DOWN
}

/*******************************************************************************
                                    Swaps
*******************************************************************************/

enum SwapKind {
    EXACT_IN,
    EXACT_OUT
}

/**
 * @dev Data for a swap operation.
 * @param kind Type of swap (Exact In or Exact Out)
 * @param pool The pool with the tokens being swapped
 * @param tokenIn The token entering the Vault (balance increases)
 * @param tokenOut The token leaving the Vault (balance decreases)
 * @param amountGivenRaw Amount specified for tokenIn or tokenOut (depending on the type of swap)
 * @param limitRaw
 * @param userData Additional (optional) user data
 */
struct SwapParams {
    SwapKind kind;
    address pool;
    IERC20 tokenIn;
    IERC20 tokenOut;
    uint256 amountGivenRaw;
    uint256 limitRaw;
    bytes userData;
}

/**
 * @dev Data for a wrap/unwrap operation using a vault buffer for a yield-bearing token.
 * @param kind Type of swap (Exact In or Exact Out)
 * @param tokenIn The token entering the Buffer (balance increases)
 * @param tokenOut The token leaving the Buffer (balance decreases)
 * @param amountGiven Amount specified for tokenIn or tokenOut (depending on the type of swap)
 */
struct WrapParams {
    SwapKind kind;
    IERC20 tokenIn;
    IERC20 tokenOut;
    uint256 amountGivenRaw;
}

/*******************************************************************************
                                Add liquidity
*******************************************************************************/

enum AddLiquidityKind {
    PROPORTIONAL,
    UNBALANCED,
    SINGLE_TOKEN_EXACT_OUT,
    CUSTOM
}

/**
 * @dev Data for an add liquidity operation.
 * @param pool Address of the pool
 * @param to Address of user to mint to
 * @param maxAmountsIn Maximum amounts of input tokens
 * @param minBptAmountOut Minimum amount of output pool tokens
 * @param kind Add liquidity kind
 * @param userData Optional user data
 */
struct AddLiquidityParams {
    address pool;
    address to;
    uint256[] maxAmountsIn;
    uint256 minBptAmountOut;
    AddLiquidityKind kind;
    bytes userData;
}

/*******************************************************************************
                                Remove liquidity
*******************************************************************************/

enum RemoveLiquidityKind {
    PROPORTIONAL,
    SINGLE_TOKEN_EXACT_IN,
    SINGLE_TOKEN_EXACT_OUT,
    CUSTOM
}

/**
 * @param pool Address of the pool
 * @param from Address of user to burn from
 * @param maxBptAmountIn Maximum amount of input pool tokens
 * @param minAmountsOut Minimum amounts of output tokens
 * @param kind Remove liquidity kind
 * @param userData Optional user data
 */
struct RemoveLiquidityParams {
    address pool;
    address from;
    uint256 maxBptAmountIn;
    uint256[] minAmountsOut;
    RemoveLiquidityKind kind;
    bytes userData;
}

// Protocol Fees are 24-bit values. We transform them by multiplying by 1e11, so
// they can be set to any value between 0% and 100% (step 0.00001%).
uint256 constant FEE_BITLENGTH = 24;
uint256 constant FEE_SCALING_FACTOR = 1e11;
