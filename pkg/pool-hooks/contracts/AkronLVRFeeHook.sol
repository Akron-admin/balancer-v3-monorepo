// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBasePoolFactory } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePoolFactory.sol";
import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-weighted/IWeightedPool.sol";
import {
    LiquidityManagement,
    TokenConfig,
    PoolSwapParams,
    AfterSwapParams,
    HookFlags,
    SwapKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { VaultGuard } from "@balancer-labs/v3-vault/contracts/VaultGuard.sol";
import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";

import { ScalingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import { ModifiedWeightedMath } from "@balancer-labs/v3-solidity-utils/contracts/math/ModifiedWeightedMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @notice Hook that implements dynamic swap fees.
 * @dev Fees are equal to expected maximum loss-versus-rebalancing.
 */
contract AkronLVRFeeHook is BaseHooks, VaultGuard {
    using FixedPoint for uint256;

    /**
     * @notice A new `AkronLVRFeeHook` contract has been registered successfully for a given factory and pool.
     * @dev If the registration fails the call will revert, so there will be no event.
     * @param hooksContract This contract
     * @param pool The pool on which the hook was registered
     */
    event LVRFeeHookRegistered(address indexed hooksContract, address indexed pool);

    struct BlockState {
        uint256[] lastBalancesScaled18;
        uint256 lastInvariant;
    }

    mapping(address pool => mapping(uint256 blocknumber => BlockState)) internal blockStates;

    constructor(IVault vault) VaultGuard(vault) {
        // solhint-disable-previous-line no-empty-blocks
    }

    /// @inheritdoc IHooks
    function getHookFlags() public pure override returns (HookFlags memory hookFlags) {
        hookFlags.shouldCallBeforeSwap = true;
        hookFlags.shouldCallComputeDynamicSwapFee = true;
    }

    /// @inheritdoc IHooks
    function onRegister(
        address,
        address pool,
        TokenConfig[] memory,
        LiquidityManagement calldata
    ) public override onlyVault returns (bool) {
        emit LVRFeeHookRegistered(address(this), pool);
        return true;
    }

    function onBeforeSwap(PoolSwapParams calldata params, address pool) public override returns (bool) {
        BlockState storage state = blockStates[pool][block.number];
        // Works only for pools supporting two tokens.
        if (state.lastInvariant == 0) {
            state.lastBalancesScaled18 = new uint256[](2);
            state.lastBalancesScaled18[params.indexIn] = params.balancesScaled18[params.indexIn];
            state.lastBalancesScaled18[params.indexOut] = params.balancesScaled18[params.indexOut];
            state.lastInvariant = params.balancesScaled18[params.indexIn] * params.balancesScaled18[params.indexOut];   
        }
        return true;
    }

    /// @inheritdoc IHooks
    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata params,
        address pool,
        uint256 
    ) public view override onlyVault returns (bool, uint256 swapFeePercentage) {
        
        uint256[] memory weights = IWeightedPool(pool).getNormalizedWeights();

        if (params.kind == SwapKind.EXACT_IN) {
            uint256 lastBalanceInScaled18 = blockStates[pool][block.number].lastBalancesScaled18[params.indexIn] 
                * Math.sqrt(
                    params.balancesScaled18[params.indexOut] 
                        * params.balancesScaled18[params.indexIn] 
                        / blockStates[pool][block.number].lastInvariant
                );

            if (params.balancesScaled18[params.indexIn] > lastBalanceInScaled18) {
                swapFeePercentage = ModifiedWeightedMath.computeSwapFeePercentageGivenExactIn(
                    lastBalanceInScaled18,
                    weights[params.indexIn].divDown(weights[params.indexOut]), 
                    params.balancesScaled18[params.indexIn] - lastBalanceInScaled18 + params.amountGivenScaled18,
                    params.balancesScaled18[params.indexIn] - lastBalanceInScaled18
                );
            } else {
                swapFeePercentage = ModifiedWeightedMath.computeSwapFeePercentageGivenExactIn(
                    params.balancesScaled18[params.indexIn], 
                    weights[params.indexIn].divDown(weights[params.indexOut]), 
                    params.amountGivenScaled18
                );
            }     
        } else {
            uint256 lastBalanceOutScaled18 = blockStates[pool][block.number].lastBalancesScaled18[params.indexOut] 
                * Math.sqrt(
                    params.balancesScaled18[params.indexOut] 
                        * params.balancesScaled18[params.indexIn] 
                        / blockStates[pool][block.number].lastInvariant
                );

            if (lastBalanceOutScaled18 > params.balancesScaled18[params.indexOut]) {
                swapFeePercentage = ModifiedWeightedMath.computeSwapFeePercentageGivenExactOut(
                    lastBalanceOutScaled18,
                    weights[params.indexOut].divUp(weights[params.indexIn]),
                    lastBalanceOutScaled18 - params.balancesScaled18[params.indexOut] + params.amountGivenScaled18,
                    lastBalanceOutScaled18 - params.balancesScaled18[params.indexOut]
                );
            } else {
                swapFeePercentage = ModifiedWeightedMath.computeSwapFeePercentageGivenExactOut(
                    params.balancesScaled18[params.indexOut], 
                    weights[params.indexOut].divUp(weights[params.indexIn]), 
                    params.amountGivenScaled18
                );
            }
        }

        return (true, swapFeePercentage);
    }
}
