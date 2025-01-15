// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-weighted/IWeightedPool.sol";
import {
    LiquidityManagement, TokenConfig, PoolSwapParams, HookFlags, SwapKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";
import { VaultGuard } from "@balancer-labs/v3-vault/contracts/VaultGuard.sol";
import { Akron5050PoolMath } from "./lib/Akron5050PoolMath.sol";

/**
 * @notice Hook that implements dynamic swap fees.
 * @dev Fees are equal to expected loss-versus-rebalancing.
 */
contract Akron5050PoolLVRFeeHook is BaseHooks, VaultGuard {
    using FixedPoint for uint256;

    /**
     * @notice A new `AkronLVRFeeHook` contract has been registered successfully for a given factory and pool.
     * @dev If the registration fails the call will revert, so there will be no event.
     * @param hooksContract This contract
     * @param pool The pool on which the hook was registered
     */
    event LVRFeeHookRegistered(address indexed hooksContract, address indexed pool);

    error SupportsOnlyTwoTokens();

    error SupportsOnlyWeighted5050Pools();

    mapping(address pool => mapping(uint256 blocknumber => uint256[])) internal lastBalancesScaled18;

    constructor(IVault vault) VaultGuard(vault) {
        // solhint-disable-previous-line no-empty-blocks
    }

    function getHookFlags() public pure override returns (HookFlags memory hookFlags) {
        hookFlags.shouldCallBeforeSwap = true;
        hookFlags.shouldCallComputeDynamicSwapFee = true;
    }

    function onRegister(
        address,
        address pool,
        TokenConfig[] memory tokenConfig,
        LiquidityManagement calldata
    ) public override onlyVault returns (bool) {
        uint256[] memory weights = IWeightedPool(pool).getNormalizedWeights();
        if (tokenConfig.length != 2 || ) revert SupportsOnlyTwoTokens();
        if (weights[0] != 50e16) revert SupportsOnlyWeighted5050Pools();

        emit LVRFeeHookRegistered(address(this), pool);
        
        return true;
    }

    function onBeforeSwap(PoolSwapParams calldata params, address pool) public override onlyVault returns (bool) {
        if (lastBalancesScaled18[pool][block.number].length == 0) {
            lastBalancesScaled18[pool][block.number] = new uint256[](params.balancesScaled18.length);
            for (uint256 i = 0; i < params.balancesScaled18.length; i++) {
                lastBalancesScaled18[pool][block.number][i] = params.balancesScaled18[i];
            }
        }
        return true;
    }

    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata params,
        address pool,
        uint256 
    ) public view override onlyVault returns (bool, uint256 swapFeePercentage) {
        uint256[] memory weights = IWeightedPool(pool).getNormalizedWeights();
        if (params.kind == SwapKind.EXACT_IN) {
        
            swapFeePercentage = Akron5050Math.computeSwapFeePercentageGivenExactIn(
                params.balancesScaled18[params.indexIn], 
                lastBalancesScaled18[pool][block.number][params.indexIn], 
                params.balancesScaled18[params.indexOut], 
                lastBalancesScaled18[pool][block.number][params.indexOut],
                params.amountGivenScaled18
            );
        } else {
            swapFeePercentage = Akron5050Math.computeSwapFeePercentageGivenExactOut(
                params.balancesScaled18[params.indexIn], 
                lastBalancesScaled18[pool][block.number][params.indexIn], 
                params.balancesScaled18[params.indexOut], 
                lastBalancesScaled18[pool][block.number][params.indexOut],
                params.amountGivenScaled18
            );
        }

        if (swapFeePercentage < IBasePool(pool).getMinimumSwapFeePercentage()) 
            swapFeePercentage = IBasePool(pool).getMinimumSwapFeePercentage();

        return (true, swapFeePercentage);
    }
}
