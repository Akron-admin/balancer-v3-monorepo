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
    AddLiquidityKind, 
    RemoveLiquidityKind,
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

    mapping(address pool => mapping(uint256 blocknumber => uint256[])) internal lastBalancesScaled18;

    constructor(IVault vault) VaultGuard(vault) {
        // solhint-disable-previous-line no-empty-blocks
    }

    /// @inheritdoc IHooks
    function getHookFlags() public pure override returns (HookFlags memory hookFlags) {
        hookFlags.shouldCallBeforeSwap = true;
        hookFlags.shouldCallComputeDynamicSwapFee = true;
        hookFlags.shouldCallAfterAddLiquidity = true;
        hookFlags.shouldCallAfterRemoveLiquidity = true;
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
        if (lastBalancesScaled18[pool][block.number].length == 0) {
            lastBalancesScaled18[pool][block.number] = new uint256[](params.balancesScaled18.length);
            for (uint256 i = 0; i < params.balancesScaled18.length; ++i) {
                lastBalancesScaled18[pool][block.number][i] = params.balancesScaled18[i];
            }
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
            uint256 lastBalanceInScaled18 = lastBalancesScaled18[pool][block.number][params.indexIn];
            if (params.balancesScaled18[params.indexIn] > lastBalanceInScaled18) {
                uint256 lastAmountGivenScaled18 = params.balancesScaled18[params.indexIn] - lastBalanceInScaled18;
                swapFeePercentage = ModifiedWeightedMath.computeSwapFeePercentageGivenExactIn(
                    lastBalanceInScaled18,
                    weights[params.indexIn].divDown(weights[params.indexOut]), 
                    lastAmountGivenScaled18 + params.amountGivenScaled18,
                    lastAmountGivenScaled18
                );
            } else {
                swapFeePercentage = ModifiedWeightedMath.computeSwapFeePercentageGivenExactIn(
                    params.balancesScaled18[params.indexIn], 
                    weights[params.indexIn].divDown(weights[params.indexOut]), 
                    params.amountGivenScaled18
                );
            }  
        } else {
            uint256 lastBalanceOutScaled18 = lastBalancesScaled18[pool][block.number][params.indexOut];
            if (lastBalanceOutScaled18 > params.balancesScaled18[params.indexOut]) {
                uint256 lastAmountGivenScaled18 = lastBalanceOutScaled18 - params.balancesScaled18[params.indexOut];
                swapFeePercentage = ModifiedWeightedMath.computeSwapFeePercentageGivenExactOut(
                    lastBalanceOutScaled18,
                    weights[params.indexOut].divUp(weights[params.indexIn]),
                    lastAmountGivenScaled18 + params.amountGivenScaled18,
                    lastAmountGivenScaled18
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

    function onAfterAddLiquidity(
        address,
        address pool,
        AddLiquidityKind,
        uint256[] memory amountsInScaled18,
        uint256[] memory amountsInRaw,
        uint256,
        uint256[] memory balancesScaled18,
        bytes memory
    ) public override returns (bool, uint256[] memory) {
        if (lastBalancesScaled18[pool][block.number].length != 0) {
            for (uint256 i = 0; i < balancesScaled18.length; ++i) {
                lastBalancesScaled18[pool][block.number][i] = 
                    lastBalancesScaled18[pool][block.number][i] 
                        * balancesScaled18[i] 
                        / (balancesScaled18[i] - amountsInScaled18[i]);
            }
        }
        return (true, amountsInRaw);
    }

    function onAfterRemoveLiquidity(
        address,
        address pool,
        RemoveLiquidityKind,
        uint256,
        uint256[] memory amountsOutScaled18,
        uint256[] memory amountsOutRaw,
        uint256[] memory balancesScaled18,
        bytes memory
    ) public override onlyVault returns (bool, uint256[] memory) {
        if (lastBalancesScaled18[pool][block.number].length != 0) {
            for (uint256 i = 0; i < balancesScaled18.length; ++i) {
                lastBalancesScaled18[pool][block.number][i] = 
                    lastBalancesScaled18[pool][block.number][i] * balancesScaled18[i] 
                        / (balancesScaled18[i] + amountsOutScaled18[i]);
            }
        }
        return (true, amountsOutRaw);
    }

}
