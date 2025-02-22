// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IPoolVersion } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IPoolVersion.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    TokenConfig,
    PoolRoleAccounts,
    LiquidityManagement
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BasePoolFactory } from "@balancer-labs/v3-pool-utils/contracts/BasePoolFactory.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";
import { WeightedPool } from "@balancer-labs/v3-pool-weighted/contracts/WeightedPool.sol";

import { AkronWeightedLVRFeeHook } from "./AkronWeightedLVRFeeHook.sol";

/// @notice Stable Pool factory that deploys a standard StablePool with a StableSurgeHook.
contract AkronWeightedPoolFactory is IPoolVersion, BasePoolFactory, Version, Ownable {
    uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    
    mapping(address hook => bool isFromFactory) private _isHookFromFactory;
    address[] private _hooks;

    string private _poolVersion;

    /// @notice The hook has not been registered.
    error HookNotRegistered();

    constructor(
        IVault vault,
        uint32 pauseWindowDuration,
        string memory factoryVersion,
        string memory poolVersion
    )
        BasePoolFactory(vault, pauseWindowDuration, type(WeightedPool).creationCode) 
        Version(factoryVersion) 
        Ownable(msg.sender)
    {
        _poolVersion = poolVersion;
    }

    /// @inheritdoc IPoolVersion
    function getPoolVersion() external view returns (string memory) {
        return _poolVersion;
    }

    /// @notice Deploy an Akron Weighted LVR Fee hook contract.
    function createHook() external returns (address hook) {
        hook = address(new AkronWeightedLVRFeeHook(getVault()));
        AkronWeightedLVRFeeHook(hook).transferOwnership(msg.sender);
        _isHookFromFactory[hook] = true;
        _hooks.push(hook);
        return hook;
    }

    /**
     * @notice Deploys a new `WeightedPool` with `AkronWeightedLVRFeeHook`.
     * @dev Tokens must be sorted for pool registration.
     * @param name The name of the pool
     * @param symbol The symbol of the pool
     * @param tokens An array of descriptors for the tokens the pool will manage
     * @param normalizedWeights The pool weights (must add to FixedPoint.ONE)
     * @param poolHooksContract Contract that implements the hooks for the pool
     * @param enableDonation If true, the pool will support the donation add liquidity mechanism
     * @param disableUnbalancedLiquidity If true, only proportional add and remove liquidity are accepted
     * @param salt The salt value that will be passed to create2 deployment
     */
    function create(
        string memory name,
        string memory symbol,
        TokenConfig[] memory tokens,
        uint256[] memory normalizedWeights,
        address poolHooksContract,
        bool enableDonation,
        bool disableUnbalancedLiquidity,
        bytes32 salt
    ) external returns (address pool) {  
        // Contract that implements the hooks for the pool must be created from factory.
        if (!_isHookFromFactory[poolHooksContract]) revert HookNotRegistered();

        PoolRoleAccounts memory roleAccounts;
        roleAccounts.poolCreator = owner();

        LiquidityManagement memory liquidityManagement = getDefaultLiquidityManagement();
        liquidityManagement.enableDonation = enableDonation;
        liquidityManagement.disableUnbalancedLiquidity = disableUnbalancedLiquidity;

        pool = _create(
            abi.encode(
                WeightedPool.NewPoolParams({
                    name: name,
                    symbol: symbol,
                    numTokens: tokens.length,
                    normalizedWeights: normalizedWeights,
                    version: _poolVersion
                }),
                getVault()
            ),
            salt
        );

        _registerPoolWithVault(
            pool,
            tokens,
            _MIN_SWAP_FEE_PERCENTAGE,
            false, // not exempt from protocol fees
            roleAccounts,
            poolHooksContract,
            liquidityManagement
        );
    }

    /// @notice Get deployed AkronWeightedLVRFeeHook contract addresses.
    function getHooks() external view returns (address[] memory hooks) {
        return _hooks;
    }
}