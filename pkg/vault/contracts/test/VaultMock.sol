// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IWETH } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultAdmin.sol";
import { IVaultExtension } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultExtension.sol";
import { IVaultMainMock } from "@balancer-labs/v3-interfaces/contracts/test/IVaultMainMock.sol";
import { IAuthorizer } from "@balancer-labs/v3-interfaces/contracts/vault/IAuthorizer.sol";
import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/vault/IRateProvider.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { EnumerableMap } from "@balancer-labs/v3-solidity-utils/contracts/openzeppelin/EnumerableMap.sol";
import { ScalingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import {
    TransientStorageHelpers
} from "@balancer-labs/v3-solidity-utils/contracts/helpers/TransientStorageHelpers.sol";
import { StorageSlot } from "@balancer-labs/v3-solidity-utils/contracts/openzeppelin/StorageSlot.sol";

import { VaultStateLib } from "../lib/VaultStateLib.sol";
import { PoolConfigBits, PoolConfigLib } from "../lib/PoolConfigLib.sol";
import { PoolFactoryMock } from "./PoolFactoryMock.sol";
import { Vault } from "../Vault.sol";
import { VaultExtension } from "../VaultExtension.sol";
import { PackedTokenBalance } from "../lib/PackedTokenBalance.sol";

import { TokenConfigLib } from "../lib/TokenConfigLib.sol";

contract VaultMock is IVaultMainMock, Vault {
    using EnumerableMap for EnumerableMap.IERC20ToBytes32Map;
    using ScalingHelpers for uint256;
    using PackedTokenBalance for bytes32;
    using PoolConfigLib for PoolConfig;
    using VaultStateLib for VaultState;
    using TransientStorageHelpers for *;
    using StorageSlot for StorageSlot.Uint256SlotType;

    constructor(IVaultExtension vaultExtension, IAuthorizer authorizer) Vault(vaultExtension, authorizer) {}

    function burnERC20(address token, address from, uint256 amount) external {
        _burn(token, from, amount);
    }

    function mintERC20(address token, address to, uint256 amount) external {
        _mint(token, to, amount);
    }

    function setConfig(address pool, PoolConfig calldata config) external {
        _poolConfig[pool] = config.fromPoolConfig();
    }

    function manualSetLockers(address[] memory lockers) public {
        uint256 lockersLength = _lockers().tLength();
        // Reset existing array
        for (uint256 i = 0; i < lockersLength; ++i) {
            _lockers().tPop();
        }

        for (uint256 i = 0; i < lockers.length; ++i) {
            _lockers().tPush(lockers[i]);
        }
    }

    function manualSetInitializedPool(address pool, bool isPoolInitialized) public {
        PoolConfig memory poolConfig = _poolConfig[pool].toPoolConfig();
        poolConfig.isPoolInitialized = isPoolInitialized;
        _poolConfig[pool] = poolConfig.fromPoolConfig();
    }

    function manualSetPoolPauseWindowEndTime(address pool, uint256 pauseWindowEndTime) public {
        PoolConfig memory poolConfig = _poolConfig[pool].toPoolConfig();
        poolConfig.pauseWindowEndTime = pauseWindowEndTime;
        _poolConfig[pool] = poolConfig.fromPoolConfig();
    }

    function manualSetPoolPaused(address pool, bool isPoolPaused) public {
        PoolConfig memory poolConfig = _poolConfig[pool].toPoolConfig();
        poolConfig.isPoolPaused = isPoolPaused;
        _poolConfig[pool] = poolConfig.fromPoolConfig();
    }

    function manualSetVaultPaused(bool isVaultPaused) public {
        VaultState memory vaultState = _vaultState.toVaultState();
        vaultState.isVaultPaused = isVaultPaused;
        _vaultState = vaultState.fromVaultState();
    }

    function manualSetVaultState(
        bool isVaultPaused,
        bool isQueryDisabled,
        uint256 protocolSwapFeePercentage,
        uint256 protocolYieldFeePercentage
    ) public {
        VaultState memory vaultState = _vaultState.toVaultState();
        vaultState.isVaultPaused = isVaultPaused;
        vaultState.isQueryDisabled = isQueryDisabled;
        vaultState.protocolSwapFeePercentage = protocolSwapFeePercentage;
        vaultState.protocolYieldFeePercentage = protocolYieldFeePercentage;
        _vaultState = vaultState.fromVaultState();
    }

    function manualSetPoolConfig(address pool, PoolConfig memory poolConfig) public {
        _poolConfig[pool] = poolConfig.fromPoolConfig();
    }

    function manualSetPoolTokenConfig(address pool, IERC20[] memory tokens, TokenConfig[] memory tokenConfig) public {
        for (uint256 i = 0; i < tokens.length; i++) {
            _poolTokenConfig[pool][tokens[i]] = tokenConfig[i];
        }
    }

    function manualSetPoolTokenBalances(address pool, IERC20[] memory tokens, uint256[] memory tokenBalanceRaw) public {
        EnumerableMap.IERC20ToBytes32Map storage poolTokenBalances = _poolTokenBalances[pool];
        for (uint256 i = 0; i < tokens.length; i++) {
            poolTokenBalances.set(tokens[i], bytes32(tokenBalanceRaw[i]));
        }
    }

    function mockWithLocker() public view withLocker {}

    function mockWithInitializedPool(address pool) public view withInitializedPool(pool) {}

    function ensurePoolNotPaused(address pool) public view {
        _ensurePoolNotPaused(pool);
    }

    function ensureUnpausedAndGetVaultState(address pool) public view returns (VaultState memory vaultState) {
        vaultState = _ensureUnpausedAndGetVaultState(pool);
    }

    function internalGetPoolTokenInfo(
        address pool
    )
        public
        view
        returns (
            TokenConfig[] memory tokenConfig,
            uint256[] memory balancesRaw,
            uint256[] memory decimalScalingFactors,
            PoolConfig memory poolConfig
        )
    {
        (tokenConfig, balancesRaw, decimalScalingFactors, poolConfig) = _getPoolTokenInfo(pool);
    }

    function recoveryModeExit(address pool) external view onlyInRecoveryMode(pool) {
        // solhint-disable-previous-line no-empty-blocks
    }

    function computePoolDataUpdatingBalancesAndFees(
        address pool,
        Rounding roundingDirection
    ) external returns (PoolData memory) {
        VaultState memory vaultState = VaultStateLib.toVaultState(_vaultState);
        return _computePoolDataUpdatingBalancesAndFees(pool, roundingDirection, vaultState.protocolYieldFeePercentage);
    }

    function updateLiveTokenBalanceInPoolData(
        PoolData memory poolData,
        Rounding roundingDirection,
        uint256 tokenIndex
    ) external pure returns (PoolData memory) {
        _updateLiveTokenBalanceInPoolData(poolData, roundingDirection, tokenIndex);
        return poolData;
    }

    function computeYieldProtocolFeesDue(
        PoolData memory poolData,
        uint256 lastLiveBalance,
        uint256 tokenIndex,
        uint256 yieldFeePercentage
    ) external pure returns (uint256) {
        return _computeYieldProtocolFeesDue(poolData, lastLiveBalance, tokenIndex, yieldFeePercentage);
    }

    function getRawBalances(address pool) external view returns (uint256[] memory balancesRaw) {
        EnumerableMap.IERC20ToBytes32Map storage poolTokenBalances = _poolTokenBalances[pool];

        uint256 numTokens = poolTokenBalances.length();
        balancesRaw = new uint256[](numTokens);
        bytes32 packedBalances;

        for (uint256 i = 0; i < numTokens; i++) {
            (, packedBalances) = poolTokenBalances.unchecked_at(i);
            balancesRaw[i] = packedBalances.getRawBalance();
        }
    }

    function getCurrentLiveBalances(address pool) external view returns (uint256[] memory currentLiveBalances) {
        EnumerableMap.IERC20ToBytes32Map storage poolTokenBalances = _poolTokenBalances[pool];
        PoolData memory poolData;

        (
            poolData.tokenConfig,
            poolData.balancesRaw,
            poolData.decimalScalingFactors,
            poolData.poolConfig
        ) = _getPoolTokenInfo(pool);

        _updateTokenRatesInPoolData(poolData);

        uint256 numTokens = poolTokenBalances.length();
        currentLiveBalances = new uint256[](numTokens);
        bytes32 packedBalances;

        for (uint256 i = 0; i < numTokens; i++) {
            (, packedBalances) = poolTokenBalances.unchecked_at(i);
            currentLiveBalances[i] = packedBalances.getRawBalance().toScaled18ApplyRateRoundDown(
                poolData.decimalScalingFactors[i],
                poolData.tokenRates[i]
            );
        }
    }

    function getLastLiveBalances(address pool) external view returns (uint256[] memory lastLiveBalances) {
        EnumerableMap.IERC20ToBytes32Map storage poolTokenBalances = _poolTokenBalances[pool];

        uint256 numTokens = poolTokenBalances.length();
        lastLiveBalances = new uint256[](numTokens);
        bytes32 packedBalances;

        for (uint256 i = 0; i < numTokens; i++) {
            (, packedBalances) = poolTokenBalances.unchecked_at(i);
            lastLiveBalances[i] = packedBalances.getLastLiveBalanceScaled18();
        }
    }

    function guardedCheckEntered() external nonReentrant {
        require(reentrancyGuardEntered());
    }

    function unguardedCheckNotEntered() external view {
        require(!reentrancyGuardEntered());
    }

    function accountDelta(IERC20 token, int256 delta, address locker) external {
        _accountDelta(token, delta, locker);
    }

    function supplyCredit(IERC20 token, uint256 credit, address locker) external {
        _supplyCredit(token, credit, locker);
    }

    function takeDebt(IERC20 token, uint256 debt, address locker) external {
        _takeDebt(token, debt, locker);
    }

    function manualSetAccountDelta(IERC20 token, address locker, int256 delta) external {
        _tokenDeltas().tSet(locker, token, delta);
    }

    function manualSetNonZeroDeltaCount(uint256 deltaCount) external {
        _nonzeroDeltaCount().tstore(deltaCount);
    }
}
