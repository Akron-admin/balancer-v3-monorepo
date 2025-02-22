// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IRouter } from "@balancer-labs/v3-interfaces/contracts/vault/IRouter.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-weighted/IWeightedPool.sol";
import {
    LiquidityManagement, TokenConfig, PoolSwapParams, HookFlags, SwapKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";
import { VaultGuard } from "@balancer-labs/v3-vault/contracts/VaultGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AkronWeightedMath } from "./utils/AkronWeightedMath.sol";
import "forge-std/console.sol";
/**
 * @notice Hook that implements dynamic swap fees.
 * @dev Fees are equal to expected loss-versus-rebalancing.
 */
contract AkronWeightedLVRFeeHook is BaseHooks, VaultGuard, Ownable {
    using FixedPoint for uint256;

    // Only trusted routers are allowed to call this hook
    address private _trustedRouter;

    // Retrieve the mapping of blockNumber for the specified pool's last swap path from token in to token out
    mapping(address pool => mapping(uint256 indexIn => mapping(uint256 indexOut => uint256))) public blockNumbers;

    /**
     * @notice A new trusted router is set by `setTrustedRouter`.
     * @param newTrustedRouter The address of the new trusted router
     */
    event TrustedRouterChanged(address indexed newTrustedRouter);

    /**
     * @notice A new `AkronWeightedLVRFeeHook` contract has been registered successfully for a given factory and pool.
     * @dev If the registration fails the call will revert, so there will be no event.
     * @param hooksContract This contract
     * @param pool The pool on which the hook was registered
     */
    event LVRFeeHookRegistered(address indexed hooksContract, address indexed pool);

    /// @notice An unauthorized Router tried to execute a swap.
    error RouterNotTrusted();
    
    /**
     * @notice A swap path from token in to token out has already been executed. 
     * `swap` may only be executed once in the current block.
     */
    error SwapAlreadyExecuted();

    constructor(IVault vault) VaultGuard(vault) Ownable(msg.sender) {
        // solhint-disable-previous-line no-empty-blocks
    }

    function getHookFlags() public pure override returns (HookFlags memory hookFlags) {
        hookFlags.shouldCallBeforeSwap = true;
        hookFlags.shouldCallComputeDynamicSwapFee = true;
    }

    function onRegister(
        address, address pool, TokenConfig[] memory, LiquidityManagement calldata
    ) public override onlyVault returns (bool) {
        emit LVRFeeHookRegistered(address(this), pool);
        return true;
    }

    /// @notice Check whether swap conditions are met
    function onBeforeSwap(PoolSwapParams calldata params, address pool) public override onlyVault returns (bool) {
        // If the Router is not trusted, the swap operation will revert.
        if (params.router != _trustedRouter) revert RouterNotTrusted();

        // If a swap path from token in to token out has already been executed in the current block, 
        // the swap operation will revert.
        if (blockNumbers[pool][params.indexIn][params.indexOut] == block.number) revert SwapAlreadyExecuted();
        blockNumbers[pool][params.indexIn][params.indexOut] = block.number;

        return true;
    }

    /// @notice Calculate the LVR fee percentage.
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
        
        uint256 minimumSwapFeePercentage = IBasePool(pool).getMinimumSwapFeePercentage();
        if (swapFeePercentage < minimumSwapFeePercentage) swapFeePercentage = minimumSwapFeePercentage;

        return (true, swapFeePercentage);
    }

    /**
     * @notice Set a new trusted router of the hook.
     * @dev This is a permissioned call. Emits a `TrustedRouterChanged` event.
     * @param newTrustedRouter The address of the new trusted router
     */
    function setTrustedRouter(address newTrustedRouter) external onlyOwner {
        _trustedRouter = newTrustedRouter;

        emit TrustedRouterChanged(newTrustedRouter);
    }

    /// @notice Get the trusted router of the hook.
    function getTrustedRouter() external view returns (address) {
        return _trustedRouter;
    }
}