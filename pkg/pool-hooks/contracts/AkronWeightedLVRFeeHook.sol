// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-weighted/IWeightedPool.sol";
import {
    LiquidityManagement, TokenConfig, PoolSwapParams, HookFlags, SwapKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";
import { VaultGuard } from "@balancer-labs/v3-vault/contracts/VaultGuard.sol";
import { AkronWeightedMath } from "./utils/AkronWeightedMath.sol";

/**
 * @notice Hook that sets dynamic swap fees equal to expected MEV from LVR.
 */
contract AkronWeightedLVRFeeHook is BaseHooks, VaultGuard {
    using FixedPoint for uint256;

    uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%

    /**
     * @notice A new `AkronWeightedLVRFeeHook` contract has been registered successfully.
     * @dev If the registration fails the call will revert, so there will be no event.
     * @param pool The pool on which the hook was registered
     */
    event HookRegistered(address indexed pool);
    
    constructor(IVault vault) VaultGuard(vault) {}

    function getHookFlags() public pure override returns (HookFlags memory hookFlags) {
        hookFlags.shouldCallComputeDynamicSwapFee = true;
    }
    
    /**
     * @notice Hook executed when a pool is registered with a non-zero hooks contract.
     */
    function onRegister(
        address, address pool, TokenConfig[] memory, LiquidityManagement calldata
    ) public override onlyVault returns (bool) {
        emit HookRegistered(pool);

        return true;
    }
    
    /**
      * @notice Calculate the LVR fee percentage.
      */
    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata params,
        address pool,
        uint256 
    ) public view override onlyVault returns (bool, uint256 swapFeePercentage) {
        uint256[] memory weights = IWeightedPool(pool).getNormalizedWeights();
        
        if (params.kind == SwapKind.EXACT_IN) {
            swapFeePercentage = AkronWeightedMath.computeSwapFeePercentageGivenExactIn(
                params.balancesScaled18[params.indexIn],
                weights[params.indexIn].divDown(weights[params.indexOut]),
                params.amountGivenScaled18
            );
        } else {
            swapFeePercentage = AkronWeightedMath.computeSwapFeePercentageGivenExactOut(
                params.balancesScaled18[params.indexOut],
                weights[params.indexOut].divUp(weights[params.indexIn]),
                params.amountGivenScaled18
            );
        }
        
        if (swapFeePercentage < _MIN_SWAP_FEE_PERCENTAGE) swapFeePercentage = _MIN_SWAP_FEE_PERCENTAGE;

        return (true, swapFeePercentage);
    }
}