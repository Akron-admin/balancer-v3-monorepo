// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.4;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IVaultEvents } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultEvents.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ScalingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { EnumerableMap } from "@balancer-labs/v3-solidity-utils/contracts/openzeppelin/EnumerableMap.sol";

import { PoolConfigBits, PoolConfigLib } from "./lib/PoolConfigLib.sol";
import { VaultStorage } from "./VaultStorage.sol";
import { ERC20MultiToken } from "./token/ERC20MultiToken.sol";
import { PackedTokenBalance } from "./lib/PackedTokenBalance.sol";

/**
 * @dev Storage layout for Vault. This contract has no code except for common utilities in the inheritance chain
 * that require storage to work and will be required in both the main Vault and its extension.
 */
abstract contract VaultCommon is IVaultEvents, IVaultErrors, VaultStorage, ReentrancyGuard, ERC20MultiToken {
    using EnumerableMap for EnumerableMap.IERC20ToBytes32Map;
    using PackedTokenBalance for bytes32;
    using ScalingHelpers for *;
    using SafeCast for *;
    using FixedPoint for *;

    /*******************************************************************************
                              Transient Accounting
    *******************************************************************************/

    /**
     * @dev This modifier ensures that the function it modifies can only be called
     * by the last handler in the `_handlers` array. This is used to enforce the
     * order of execution when multiple handlers are in play, ensuring only the
     * current or "active" handler can invoke certain operations in the Vault.
     * If no handler is found or the caller is not the expected handler,
     * it reverts the transaction with specific error messages.
     */
    modifier withHandler() {
        // If there are no handlers in the list, revert with an error.
        if (_handlers.length == 0) {
            revert NoHandler();
        }

        // Get the last handler from the `_handlers` array.
        // This represents the current active handler.
        address handler = _handlers[_handlers.length - 1];

        // If the current function caller is not the active handler, revert.
        if (msg.sender != handler) revert WrongHandler(msg.sender, handler);

        _;
    }

    /**
     * @notice Expose the state of the Vault's reentrancy guard.
     * @return True if the Vault is currently executing a nonReentrant function
     */
    function reentrancyGuardEntered() public view returns (bool) {
        return _reentrancyGuardEntered();
    }

    /**
     * @notice Records the `credit` for a given handler and token.
     * @param token   The ERC20 token for which the 'credit' will be accounted.
     * @param credit  The amount of `token` supplied to the Vault in favor of the `handler`.
     * @param handler The account credited with the amount.
     */
    function _supplyCredit(IERC20 token, uint256 credit, address handler) internal {
        _accountDelta(token, -credit.toInt256(), handler);
    }

    /**
     * @notice Records the `debt` for a given handler and token.
     * @param token   The ERC20 token for which the `debt` will be accounted.
     * @param debt    The amount of `token` taken from the Vault in favor of the `handler`.
     * @param handler The account responsible for the debt.
     */
    function _takeDebt(IERC20 token, uint256 debt, address handler) internal {
        _accountDelta(token, debt.toInt256(), handler);
    }

    /**
     * @dev Accounts the delta for the given handler and token.
     * Positive delta represents debt, while negative delta represents surplus.
     * The function ensures that only the specified handler can update its respective delta.
     *
     * @param token   The ERC20 token for which the delta is being accounted.
     * @param delta   The difference in the token balance.
     *                Positive indicates a debit or a decrease in Vault's tokens,
     *                negative indicates a credit or an increase in Vault's tokens.
     * @param handler The handler whose balance difference is being accounted for.
     *                Must be the same as the caller of the function.
     */
    function _accountDelta(IERC20 token, int256 delta, address handler) internal {
        // If the delta is zero, there's nothing to account for.
        if (delta == 0) return;

        // Ensure that the handler specified is indeed the caller.
        if (handler != msg.sender) {
            revert WrongHandler(handler, msg.sender);
        }

        // Get the current recorded delta for this token and handler.
        int256 current = _tokenDeltas[handler][token];

        // Calculate the new delta after accounting for the change.
        int256 next = current + delta;

        unchecked {
            // If the resultant delta becomes zero after this operation,
            // decrease the count of non-zero deltas.
            if (next == 0) {
                _nonzeroDeltaCount--;
            }
            // If there was no previous delta (i.e., it was zero) and now we have one,
            // increase the count of non-zero deltas.
            else if (current == 0) {
                _nonzeroDeltaCount++;
            }
        }

        // Update the delta for this token and handler.
        _tokenDeltas[handler][token] = next;
    }

    function _isTrustedRouter(address) internal pure returns (bool) {
        //TODO: Implement based on approval by governance and user
        return true;
    }

    /*******************************************************************************
                                    Vault Pausing
    *******************************************************************************/

    /// @dev Modifier to make a function callable only when the Vault is not paused.
    modifier whenVaultNotPaused() {
        _ensureVaultNotPaused();
        _;
    }

    /// @dev Reverts if the Vault is paused.
    function _ensureVaultNotPaused() internal view {
        if (_isVaultPaused()) {
            revert VaultPaused();
        }
    }

    /**
     * @dev For gas efficiency, storage is only read before `_vaultBufferPeriodEndTime`. Once we're past that
     * timestamp, the expression short-circuits false, and the Vault is permanently unpaused.
     */
    function _isVaultPaused() internal view returns (bool) {
        // solhint-disable-next-line not-rely-on-time
        return block.timestamp <= _vaultBufferPeriodEndTime && _vaultPaused;
    }

    /*******************************************************************************
                                     Pool Pausing
    *******************************************************************************/

    /// @dev Modifier to make a function callable only when the Vault and Pool are not paused.
    modifier whenPoolNotPaused(address pool) {
        _ensureVaultNotPaused();
        _ensurePoolNotPaused(pool);
        _;
    }

    /**
     * @dev Reverts if the pool is paused.
     * @param pool The pool
     */
    function _ensurePoolNotPaused(address pool) internal view {
        if (_isPoolPaused(pool)) {
            revert PoolPaused(pool);
        }
    }

    /// @dev Check both the flag and timestamp to determine whether the pool is paused.
    function _isPoolPaused(address pool) internal view returns (bool) {
        (bool paused, ) = _getPoolPausedState(pool);

        return paused;
    }

    /// @dev Lowest level routine that plucks only the minimum necessary parts from storage.
    function _getPoolPausedState(address pool) internal view returns (bool, uint256) {
        (bool pauseBit, uint256 pauseWindowEndTime) = PoolConfigLib.getPoolPausedState(_poolConfig[pool]);

        // Use the Vault's buffer period.
        // solhint-disable-next-line not-rely-on-time
        return (pauseBit && block.timestamp <= pauseWindowEndTime + _vaultBufferPeriodDuration, pauseWindowEndTime);
    }

    /*******************************************************************************
                            Pool Registration and Initialization
    *******************************************************************************/

    /// @dev Reverts unless `pool` corresponds to a registered Pool.
    modifier withRegisteredPool(address pool) {
        _ensureRegisteredPool(pool);
        _;
    }

    /// @dev Reverts unless `pool` corresponds to an intialized Pool.
    modifier withInitializedPool(address pool) {
        _ensureInitializedPool(pool);
        _;
    }

    /// @dev Reverts unless `pool` corresponds to a registered Pool.
    function _ensureRegisteredPool(address pool) internal view {
        if (!_isPoolRegistered(pool)) {
            revert PoolNotRegistered(pool);
        }
    }

    /// @dev See `isPoolRegistered`
    function _isPoolRegistered(address pool) internal view returns (bool) {
        return _poolConfig[pool].isPoolRegistered();
    }

    /// @dev Reverts unless `pool` corresponds to an initialized Pool.
    function _ensureInitializedPool(address pool) internal view {
        if (!_isPoolInitialized(pool)) {
            revert PoolNotInitialized(pool);
        }
    }

    /// @dev See `isPoolInitialized`
    function _isPoolInitialized(address pool) internal view returns (bool) {
        return _poolConfig[pool].isPoolInitialized();
    }

    /*******************************************************************************
                                    Pool Information
    *******************************************************************************/

    /**
     * @dev Sets the raw balances of a Pool's tokens to the current values in poolData.balancesRaw, then also
     * computes and stores the last live balances in the same slot.
     *
     * NB: Mutates poolData so that the live balances match the stored values.
     */
    function _setPoolBalances(address pool, PoolData memory poolData) internal {
        EnumerableMap.IERC20ToBytes32Map storage poolBalances = _poolTokenBalances[pool];

        // TODO: consider moving scaling into the loop below. (Tried it: saves gas, but costs bytecode.)
        poolData.balancesLiveScaled18 = poolData.balancesRaw.copyToScaled18ApplyRateRoundDownArray(
            poolData.decimalScalingFactors,
            poolData.tokenRates
        );

        for (uint256 i = 0; i < poolData.balancesRaw.length; ++i) {
            // Since we assume all newBalances are properly ordered, we can simply use `unchecked_setAt`
            // to avoid one less storage read per token.
            poolBalances.unchecked_setAt(
                i,
                PackedTokenBalance.toPackedBalance(poolData.balancesRaw[i], poolData.balancesLiveScaled18[i])
            );
        }
    }

    /**
     * @notice Fetches the tokens and their corresponding balances for a given pool.
     * @dev Utilizes an enumerable map to obtain pool token balances.
     * The function is structured to minimize storage reads by leveraging the `unchecked_at` method.
     *
     * @param pool The address of the pool for which tokens and balances are to be fetched.
     * @return tokens An array of token addresses.
     */
    function _getPoolTokens(address pool) internal view returns (IERC20[] memory tokens) {
        // Retrieve the mapping of tokens and their balances for the specified pool.
        EnumerableMap.IERC20ToBytes32Map storage poolTokenBalances = _poolTokenBalances[pool];
        mapping(IERC20 => TokenConfig) storage poolTokenConfig = _poolTokenConfig[pool];

        // Initialize arrays to store tokens based on the number of tokens in the pool.
        tokens = new IERC20[](poolTokenBalances.length());

        for (uint256 i = 0; i < tokens.length; ++i) {
            // Because the iteration is bounded by `tokens.length`, which matches the EnumerableMap's length,
            // we can safely use `unchecked_at`. This ensures that `i` is a valid token index and minimizes
            // storage reads.
            (IERC20 token, ) = poolTokenBalances.unchecked_at(i);

            // Translate tokens of type ERC4626 to base tokens (except for buffer pools)
            if (
                poolTokenConfig[token].tokenType == TokenType.ERC4626 &&
                _wrappedTokenBuffers[IERC4626(address(token))] != pool
            ) {
                tokens[i] = IERC20(IERC4626(address(token)).asset());
            } else {
                tokens[i] = token;
            }
        }
    }

    function _getPoolTokenInfo(
        address pool
    )
        internal
        view
        returns (
            TokenConfig[] memory tokenConfig,
            uint256[] memory balancesRaw,
            uint256[] memory decimalScalingFactors,
            PoolConfig memory poolConfig
        )
    {
        EnumerableMap.IERC20ToBytes32Map storage poolTokenBalances = _poolTokenBalances[pool];
        mapping(IERC20 => TokenConfig) storage poolTokenConfig = _poolTokenConfig[pool];

        uint256 numTokens = poolTokenBalances.length();
        poolConfig = _poolConfig[pool].toPoolConfig();

        tokenConfig = new TokenConfig[](numTokens);
        balancesRaw = new uint256[](numTokens);
        decimalScalingFactors = PoolConfigLib.getDecimalScalingFactors(poolConfig, numTokens);
        bytes32 packedBalance;
        IERC20 token;

        for (uint256 i = 0; i < numTokens; i++) {
            (token, packedBalance) = poolTokenBalances.unchecked_at(i);
            balancesRaw[i] = packedBalance.getRawBalance();
            tokenConfig[i] = poolTokenConfig[token];
        }
    }

    /**
     * @dev Mutates poolData to add token rates. Assumes tokenConfig is already set.
     */
    function _updateTokenRatesInPoolData(PoolData memory poolData) internal view {
        uint256 numTokens = poolData.tokenConfig.length;

        // Initialize arrays to store tokens based on the number of tokens in the pool.
        poolData.tokenRates = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; ++i) {
            TokenType tokenType = poolData.tokenConfig[i].tokenType;

            if (tokenType == TokenType.STANDARD) {
                poolData.tokenRates[i] = FixedPoint.ONE;
            } else if (tokenType == TokenType.WITH_RATE) {
                poolData.tokenRates[i] = poolData.tokenConfig[i].rateProvider.getRate();
            } else if (tokenType == TokenType.ERC4626) {
                poolData.tokenRates[i] = IRateProvider(
                    _wrappedTokenBuffers[IERC4626(address(poolData.tokenConfig[i].token))]
                ).getRate();
            } else {
                revert InvalidTokenConfiguration();
            }
        }
    }

    /**
     * @dev Get poolData and compute protocol yield fees due, without changing any state.
     * Returns poolData with both raw and live balances updated to reflect the fees.
     */
    function _getPoolDataAndYieldFees(
        address pool,
        Rounding roundingDirection
    ) internal view returns (PoolData memory poolData, uint256[] memory dueProtocolYieldFees) {
        // Initialize poolData with base information for subsequent calculations.
        (
            poolData.tokenConfig,
            poolData.balancesRaw,
            poolData.decimalScalingFactors,
            poolData.poolConfig
        ) = _getPoolTokenInfo(pool);

        EnumerableMap.IERC20ToBytes32Map storage poolBalances = _poolTokenBalances[pool];
        uint256 numTokens = poolBalances.length();

        dueProtocolYieldFees = new uint256[](numTokens);

        // Initialize arrays to store balances and rates based on the number of tokens in the pool.
        // Will be read raw, then upscaled and rounded as directed.
        poolData.balancesLiveScaled18 = new uint256[](numTokens);
        uint256 yieldFeePercentage = _protocolYieldFeePercentage;

        // Fill in the tokenRates inside poolData (needed for `_updateLiveTokenBalanceInPoolData`).
        _updateTokenRatesInPoolData(poolData);

        bool poolSubjectToYieldFees = poolData.poolConfig.isPoolInitialized &&
            yieldFeePercentage > 0 &&
            poolData.poolConfig.isPoolInRecoveryMode == false;

        for (uint256 i = 0; i < numTokens; ++i) {
            TokenType tokenType = poolData.tokenConfig[i].tokenType;

            // This sets the live balance in poolData from the raw balance, applying scaling and rates,
            // and respecting the rounding direction. Charging a yield fee changes the raw
            // balance, in which case the safest and most numerically precise way to adjust
            // the live balance is to simply repeat the scaling (hence the second call below).
            _updateLiveTokenBalanceInPoolData(poolData, roundingDirection, i);

            bool tokenSubjectToYieldFees = tokenType == TokenType.ERC4626 ||
                (tokenType == TokenType.WITH_RATE && poolData.tokenConfig[i].yieldFeeExempt == false);

            // Do not charge yield fees until the pool is initialized, and is not in recovery mode.
            // ERC4626 tokens always pay yield fees; WITH_RATE tokens pay unless exempt.
            if (poolSubjectToYieldFees && tokenSubjectToYieldFees) {
                uint256 yieldFeeAmountRaw = _computeYieldProtocolFeesDue(
                    poolData,
                    poolBalances.unchecked_valueAt(i).getLastLiveBalanceScaled18(),
                    i,
                    yieldFeePercentage
                );

                if (yieldFeeAmountRaw > 0) {
                    dueProtocolYieldFees[i] = yieldFeeAmountRaw;

                    // Adjust raw and live balances.
                    poolData.balancesRaw[i] -= yieldFeeAmountRaw;
                    _updateLiveTokenBalanceInPoolData(poolData, roundingDirection, i);
                }
            }
        }
    }

    /**
     * @dev Fill in PoolData, including paying protocol yield fees and computing final raw and live balances.
     * This function modifies protocol fees and balance storage. Since it modifies storage and makes external
     * calls, it must be nonReentrant.
     */
    function _computePoolDataUpdatingBalancesAndFees(
        address pool,
        Rounding roundingDirection
    ) internal nonReentrant returns (PoolData memory poolData) {
        uint256[] memory dueProtocolYieldFees;

        (poolData, dueProtocolYieldFees) = _getPoolDataAndYieldFees(pool, roundingDirection);
        uint256 numTokens = dueProtocolYieldFees.length;

        for (uint256 i = 0; i < numTokens; ++i) {
            IERC20 token = poolData.tokenConfig[i].token;
            uint256 yieldFeeAmountRaw = dueProtocolYieldFees[i];

            if (yieldFeeAmountRaw > 0) {
                // Charge protocol fee.
                _protocolFees[token] += yieldFeeAmountRaw;
                emit ProtocolYieldFeeCharged(pool, address(token), yieldFeeAmountRaw);
            }
        }

        // Update raw and last live pool balances, as computed by `_getPoolDataAndYieldFees`
        _setPoolBalances(pool, poolData);
    }

    function _computeYieldProtocolFeesDue(
        PoolData memory poolData,
        uint256 lastLiveBalance,
        uint256 tokenIndex,
        uint256 yieldFeePercentage
    ) internal pure returns (uint256 feeAmountRaw) {
        uint256 currentLiveBalance = poolData.balancesLiveScaled18[tokenIndex];

        // Do not charge fees if rates go down. If the rate were to go up, down, and back up again, protocol fees
        // would be charged multiple times on the "same" yield. For tokens subject to yield fees, this should not
        // happen, or at least be very rare. It can be addressed for known volatile rates by setting the yield fee
        // exempt flag on registration, or compensated off-chain if there is an incident with a normally
        // well-behaved rate provider.
        if (currentLiveBalance > lastLiveBalance) {
            unchecked {
                // Magnitudes checked above, so it's safe to do unchecked math here.
                uint256 liveBalanceDiff = currentLiveBalance - lastLiveBalance;

                feeAmountRaw = liveBalanceDiff.mulDown(yieldFeePercentage).toRawUndoRateRoundDown(
                    poolData.decimalScalingFactors[tokenIndex],
                    poolData.tokenRates[tokenIndex]
                );
            }
        }
    }

    /**
     * @dev Updates the live balance of a given token in poolData, scaling the raw balance by both decimal
     * and token rates, and rounding the result in the given direction. Assumes raw balances, scaling factors,
     * and rates are current in PoolData.
     */
    function _updateLiveTokenBalanceInPoolData(
        PoolData memory poolData,
        Rounding roundingDirection,
        uint256 tokenIndex
    ) internal pure {
        function(uint256, uint256, uint256) internal pure returns (uint256) _upOrDown = roundingDirection ==
            Rounding.ROUND_UP
            ? ScalingHelpers.toScaled18ApplyRateRoundUp
            : ScalingHelpers.toScaled18ApplyRateRoundDown;

        poolData.balancesLiveScaled18[tokenIndex] = _upOrDown(
            poolData.balancesRaw[tokenIndex],
            poolData.decimalScalingFactors[tokenIndex],
            poolData.tokenRates[tokenIndex]
        );
    }

    /*******************************************************************************
                                    Recovery Mode
    *******************************************************************************/

    /**
     * @dev Place on functions that may only be called when the associated pool is in recovery mode.
     * @param pool The pool
     */
    modifier onlyInRecoveryMode(address pool) {
        _ensurePoolInRecoveryMode(pool);
        _;
    }

    /**
     * @dev Reverts if the pool is not in recovery mode.
     * @param pool The pool
     */
    function _ensurePoolInRecoveryMode(address pool) internal view {
        if (!_isPoolInRecoveryMode(pool)) {
            revert PoolNotInRecoveryMode(pool);
        }
    }

    /**
     * @notice Checks whether a pool is in recovery mode.
     * @param pool Address of the pool to check
     * @return True if the pool is initialized, false otherwise
     */
    function _isPoolInRecoveryMode(address pool) internal view returns (bool) {
        return _poolConfig[pool].isPoolInRecoveryMode();
    }
}
