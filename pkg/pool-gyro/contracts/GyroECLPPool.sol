// SPDX-License-Identifier: LicenseRef-Gyro-1.0
// for information on licensing please see the README in the GitHub repository
// <https://github.com/gyrostable/concentrated-lps>.

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { BalancerPoolToken } from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import { SwapKind } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import "./lib/GyroPoolMath.sol";
import "./lib/GyroECLPMath.sol";

contract Gyro2CLPPool is IBasePool, BalancerPoolToken {
    using FixedPoint for uint256;

    /// @dev Parameters of the ECLP pool
    int256 internal immutable _paramsAlpha;
    int256 internal immutable _paramsBeta;
    int256 internal immutable _paramsC;
    int256 internal immutable _paramsS;
    int256 internal immutable _paramsLambda;
    int256 internal immutable _tauAlphaX;
    int256 internal immutable _tauAlphaY;
    int256 internal immutable _tauBetaX;
    int256 internal immutable _tauBetaY;
    int256 internal immutable _u;
    int256 internal immutable _v;
    int256 internal immutable _w;
    int256 internal immutable _z;
    int256 internal immutable _dSq;
    bytes32 private constant _POOL_TYPE = "ECLP";

    struct GyroParams {
        string name;
        string symbol;
        GyroECLPMath.Params eclpParams;
        GyroECLPMath.DerivedParams derivedEclpParams;
    }

    error SqrtParamsWrong();
    error SupportsOnlyTwoTokens();
    error NotImplemented();
    error AddressIsZeroAddress();


    event ECLPParamsValidated(bool paramsValidated);
    event ECLPDerivedParamsValidated(bool derivedParamsValidated);
    event InvariantAterInitializeJoin(uint256 invariantAfterJoin);
    event InvariantOldAndNew(uint256 oldInvariant, uint256 newInvariant);

    constructor(GyroParams memory params, IVault vault) BalancerPoolToken(vault, params.name, params.symbol) {
        GyroECLPMath.validateParams(params.eclpParams);
        emit ECLPParamsValidated(true);

        GyroECLPMath.validateDerivedParamsLimits(params.eclpParams, params.derivedEclpParams);
        emit ECLPDerivedParamsValidated(true);

        (_paramsAlpha, _paramsBeta, _paramsC, _paramsS, _paramsLambda) = (
            params.eclpParams.alpha,
            params.eclpParams.beta,
            params.eclpParams.c,
            params.eclpParams.s,
            params.eclpParams.lambda
        );

        (_tauAlphaX, _tauAlphaY, _tauBetaX, _tauBetaY, _u, _v, _w, _z, _dSq) = (
            params.derivedEclpParams.tauAlpha.x,
            params.derivedEclpParams.tauAlpha.y,
            params.derivedEclpParams.tauBeta.x,
            params.derivedEclpParams.tauBeta.y,
            params.derivedEclpParams.u,
            params.derivedEclpParams.v,
            params.derivedEclpParams.w,
            params.derivedEclpParams.z,
            params.derivedEclpParams.dSq
        );
    }

    /// @inheritdoc IBasePool
    function getPoolTokens() public view returns (IERC20[] memory tokens) {
        return getVault().getPoolTokens(address(this));
    }

    /// @inheritdoc IBasePool
    function computeInvariant(uint256[] memory balancesLiveScaled18) public view returns (uint256) {
        (GyroECLPMath.Params memory eclpParams, GyroECLPMath.DerivedParams memory derivedECLPParams) = reconstructECLPParams();
        
        return GyroECLPMath.calculateInvariant(balancesLiveScaled18, eclpParams, derivedECLPParams);
    }

    /// @inheritdoc IBasePool
    function computeBalance(
        uint256[] memory balancesLiveScaled18,
        uint256 tokenInIndex,
        uint256 invariantRatio
    ) external view returns (uint256 newBalance) {
        computeInvariant(balancesLiveScaled18);

        revert NotImplemented();
    }

    /// @inheritdoc IBasePool
    function onSwap(IBasePool.PoolSwapParams memory request) public view onlyVault returns (uint256) {
        bool tokenInIsToken0 = request.indexIn == 0;

        (GyroECLPMath.Params memory eclpParams, GyroECLPMath.DerivedParams memory derivedECLPParams) = reconstructECLPParams();
        GyroECLPMath.Vector2 memory invariant;
        {
            (int256 currentInvariant, int256 invErr) = GyroECLPMath.calculateInvariantWithError(
                request.balancesScaled18,
                eclpParams,
                derivedECLPParams
            );
            // invariant = overestimate in x-component, underestimate in y-component
            // No overflow in `+` due to constraints to the different values enforced in GyroECLPMath.
            invariant = GyroECLPMath.Vector2(currentInvariant + 2 * invErr, currentInvariant);
        }

        if (request.kind == SwapKind.EXACT_IN) {
            uint256 amountOutScaled18 = GyroECLPMath.calcOutGivenIn(
                request.balancesScaled18,
                request.amountGivenScaled18,
                tokenInIsToken0,
                eclpParams,
                derivedECLPParams,
                invariant
            );

            return amountOutScaled18;
        } else {
            uint256 amountInScaled18 = GyroECLPMath.calcInGivenOut(
                request.balancesScaled18,
                request.amountGivenScaled18,
                tokenInIsToken0,
                eclpParams,
                derivedECLPParams,
                invariant
            );

            // Fees are added after scaling happens, to reduce the complexity of the rounding direction analysis.
            return amountInScaled18;
        }
    }


    /** @dev reconstructs ECLP params structs from immutable arrays */
    function reconstructECLPParams() internal view returns (GyroECLPMath.Params memory params, GyroECLPMath.DerivedParams memory d) {
        (params.alpha, params.beta, params.c, params.s, params.lambda) = (_paramsAlpha, _paramsBeta, _paramsC, _paramsS, _paramsLambda);
        (d.tauAlpha.x, d.tauAlpha.y, d.tauBeta.x, d.tauBeta.y) = (_tauAlphaX, _tauAlphaY, _tauBetaX, _tauBetaY);
        (d.u, d.v, d.w, d.z, d.dSq) = (_u, _v, _w, _z, _dSq);
    }

    function getECLPParams() external view returns (GyroECLPMath.Params memory params, GyroECLPMath.DerivedParams memory d) {
        return reconstructECLPParams();
    }
}
