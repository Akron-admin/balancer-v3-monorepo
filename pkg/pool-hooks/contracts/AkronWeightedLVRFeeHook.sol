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
import { AkronMath } from "./lib/AkronMath.sol";
import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";
import { VaultGuard } from "@balancer-labs/v3-vault/contracts/VaultGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";

/**
 * @notice Hook that implements dynamic swap fees.
 * @dev Fees are equal to expected loss-versus-rebalancing.
 */
contract AkronWeightedLVRFeeHook is BaseHooks, VaultGuard {
    using FixedPoint for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal constant _MAX_ZERO_SWAP_TX_DURATION = 1 hours;

    /**
     * @notice A new `AkronWeightedLVRFeeHook` contract has been registered successfully for a given factory and pool.
     * @dev If the registration fails the call will revert, so there will be no event.
     * @param hooksContract This contract
     * @param pool The pool on which the hook was registered
     */
    event LVRFeeHookRegistered(address indexed hooksContract, address indexed pool);

    /// @notice Emitted when a state is updated
    /// @param pool The corresponding pool
    /// @param indexIn The zero-based index of tokenIn
    /// @param indexOut The zero-based index of tokenOut
    /// @param owner The owner of the existing state
    /// @param spender The spender of the existing state
    /// @param bptAmount The updated amountIn
    event UpdateState(
        address pool,
        uint256 indexIn, 
        uint256 indexOut, 
        address owner,
        address spender,
        uint256 bptAmount
    );

    /// @notice Thrown when account other than the designated spender attempts to interact with an order
    error MustBeSpender();

    /// @notice Thrown when the designated spender is the zero address
    error SpenderZeroAddress();

    /// @notice Thrown when topBidAmount is greater or equal to bidAmount
    error BidAmountTooLow(uint256 topBidAmount, uint256 bidAmount);

    error BidDurationTooShort();

    error SwapDisabled();

    constructor(IVault vault) VaultGuard(vault) {
        // solhint-disable-previous-line no-empty-blocks
    }

    struct State {
        address owner;
        address spender;
        uint256 bptAmount;
        uint256 spenderUpdateBlockTimestamp;
        uint256 swapBlockTimestamp;
        mapping(uint256 blocknumber => bool) disableSwap;
    }

    mapping(address pool => mapping(uint256 indexIn => mapping(uint256 indexOut => State))) public states;

    /// @notice Update a bid to manage designated spender
    /// @param pool The pool for which to identify the amm pool of the state
    /// @param indexIn The zero-based index of tokenIn
    /// @param indexOut The zero-based index of tokenOut
    /// @param bptAmountDelta The delta for the state sell amount. Negative to remove from state, positive to add
    function bid(address pool, uint256 indexIn, uint256 indexOut, int256 bptAmountDelta, address spender) external payable {
        State storage state = states[pool][indexIn][indexOut];
        if (state.owner != msg.sender) {
            if (state.owner != address(0)) {
                if (uint256(bptAmountDelta) < state.bptAmount) {
                    revert BidAmountTooLow(uint256(bptAmountDelta), state.bptAmount);
                }
                IERC20(pool).safeTransfer(msg.sender, state.bptAmount);
                state.bptAmount = 0;
            }
            state.owner = msg.sender;
            if (spender == address(0)) revert SpenderZeroAddress();
            state.spender = spender;
        }

        if (bptAmountDelta < 0) {
            if (state.spenderUpdateBlockTimestamp == block.timestamp) revert BidDurationTooShort();
            state.bptAmount -= uint256(-bptAmountDelta);
            IERC20(pool).safeTransfer(msg.sender, uint256(-bptAmountDelta));
            if (state.bptAmount == 0) {
                state.owner = address(0);
                state.spender = address(0);
            }
        } else {
            state.spenderUpdateBlockTimestamp == block.timestamp;
            IERC20(pool).safeTransferFrom(msg.sender, address(this), uint256(bptAmountDelta));
            state.bptAmount += uint256(bptAmountDelta);
        }
        
        emit UpdateState(pool, indexIn, indexOut, state.owner, state.spender, state.bptAmount);
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

    /**
     * @notice Store pool's starting balances
    */
    function onBeforeSwap(PoolSwapParams calldata params, address pool) public override onlyVault returns (bool) {
        State storage state = states[pool][params.indexIn][params.indexOut];
        if (block.timestamp > state.swapBlockTimestamp + _MAX_ZERO_SWAP_TX_DURATION) {
            if (state.owner != address(0)) IERC20(pool).safeTransfer(state.owner, state.bptAmount);
            state.bptAmount = 0;
            state.owner = address(0);
            state.spender = address(0);
        }
        state.swapBlockTimestamp = block.timestamp;
        uint256 blockNumber = block.number;
        if (state.spender != address(0) && state.spender != msg.sender) revert MustBeStateTrader();
        if (state.disableSwap[blockNumber]) revert SwapDisabled();
        state.disableSwap[blockNumber] = true;
        
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
            swapFeePercentage = AkronMath.computeSwapFeePercentageGivenExactIn(
                params.balancesScaled18[params.indexIn],
                weights[params.indexIn].divDown(weights[params.indexOut]),
                params.amountGivenScaled18
            );
        } else {
            swapFeePercentage = AkronMath.computeSwapFeePercentageGivenExactOut(
                params.balancesScaled18[params.indexOut],
                weights[params.indexOut].divUp(weights[params.indexIn]),
                params.amountGivenScaled18
            );
        }
        
        uint256 minimumSwapFeePercentage = IBasePool(pool).getMinimumSwapFeePercentage();
        if (swapFeePercentage < minimumSwapFeePercentage) swapFeePercentage = minimumSwapFeePercentage;

        return (true, swapFeePercentage);
    }

    /// @notice Getter for pool's normalizedWeights.
    function getNormalizedWeights(address pool) external view returns (uint256[] memory) {
        return  IWeightedPool(pool).getNormalizedWeights();
    }
}