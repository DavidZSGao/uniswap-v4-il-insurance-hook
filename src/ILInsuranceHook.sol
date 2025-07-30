// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Gaozhesi
// IL Insurance Hook for Uniswap V4 - Original Implementation
// Created: July 2025
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {ILMath} from "./ILMath.sol";

/**
 * @title ILInsuranceHook
 * @notice A Uniswap V4 hook that provides impermanent loss insurance for liquidity providers
 * @dev Collects premiums on swaps and compensates LPs when IL exceeds a threshold
 */
contract ILInsuranceHook is IHooks {
    using PoolIdLibrary for PoolKey;

    // Events
    event PremiumCollected(PoolId indexed poolId, address indexed swapper, uint256 amount);
    event InsurancePayout(PoolId indexed poolId, address indexed provider, uint256 amount);
    event PoolRegistered(PoolId indexed poolId, uint256 premiumBps, uint256 ilThresholdBps);

    // Debug events to track hook callback invocations
    event DebugAddLiquidity(
        PoolId indexed poolId, address indexed sender, uint160 sqrtPrice, uint256 amount0, uint256 amount1
    );
    event DebugRemoveLiquidity(PoolId indexed poolId, address indexed sender, uint160 sqrtPrice, uint256 ilBps);

    // Errors
    error InsufficientInsurancePool();
    error InvalidThreshold();
    error PoolNotRegistered();

    // State variables
    struct PoolConfig {
        uint256 premiumBps; // Premium rate in basis points (e.g., 2 = 0.02%)
        uint256 ilThresholdBps; // IL threshold in basis points (e.g., 100 = 1%)
        bool isActive;
    }

    // LP Position tracking for IL calculation
    struct LPPosition {
        uint160 initialSqrtPrice; // sqrt price when position was opened
        uint256 initialAmount0; // initial token0 amount
        uint256 initialAmount1; // initial token1 amount
        uint256 timestamp; // when position was opened
        bool isActive; // whether position is still active
    }

    mapping(PoolId => PoolConfig) public poolConfigs;
    mapping(PoolId => uint256) public insurancePool;
    mapping(PoolId => mapping(address => LPPosition)) public lpPositions;

    IPoolManager public immutable poolManager;
    uint256 public defaultPremiumBps;
    uint256 public defaultThresholdBps;

    constructor(IPoolManager _poolManager, uint256 _defaultPremiumBps, uint256 _defaultThresholdBps) {
        poolManager = _poolManager;
        defaultPremiumBps = _defaultPremiumBps;
        defaultThresholdBps = _defaultThresholdBps;

        // Validate hook permissions
        Hooks.validateHookPermissions(
            this,
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    /**
     * @notice Initialize pool configuration when a new pool is created
     */
    function beforeInitialize(address, PoolKey calldata key, uint160) external override returns (bytes4) {
        PoolId poolId = key.toId();

        // Use default values for premium and threshold settings
        uint256 premiumBps = defaultPremiumBps;
        uint256 ilThresholdBps = defaultThresholdBps;

        if (ilThresholdBps == 0 || ilThresholdBps > 10000) revert InvalidThreshold();

        poolConfigs[poolId] = PoolConfig({premiumBps: premiumBps, ilThresholdBps: ilThresholdBps, isActive: true});

        emit PoolRegistered(poolId, premiumBps, ilThresholdBps);

        return this.beforeInitialize.selector;
    }

    /**
     * @notice Record LP position value when liquidity is added
     */
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();

        if (!poolConfigs[poolId].isActive) revert PoolNotRegistered();

        // Get current pool state
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Calculate the amounts that will be added (simplified)
        // In a real implementation, you'd use the exact liquidity math
        uint256 amount0 = params.liquidityDelta > 0 ? uint256(int256(params.liquidityDelta)) : 0;
        uint256 amount1 = params.liquidityDelta > 0 ? uint256(int256(params.liquidityDelta)) : 0;

        // Record the initial LP position state
        // Note: Using msg.sender (router) as the position key since that's who calls the hook
        // In production, you might want to extract the actual user from calldata
        address positionOwner = msg.sender; // This will be the router contract
        lpPositions[poolId][positionOwner] = LPPosition({
            initialSqrtPrice: sqrtPriceX96,
            initialAmount0: amount0,
            initialAmount1: amount1,
            timestamp: block.timestamp,
            isActive: true
        });

        // Debug: Emit event to confirm hook callback fired
        emit DebugAddLiquidity(poolId, positionOwner, sqrtPriceX96, amount0, amount1);

        return this.beforeAddLiquidity.selector;
    }

    /**
     * @notice Calculate and pay out insurance if IL exceeds threshold when removing liquidity
     */
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();

        if (!poolConfigs[poolId].isActive) revert PoolNotRegistered();

        // Get the LP position for this user (using same key as beforeAddLiquidity)
        address positionOwner = msg.sender; // This will be the router contract
        LPPosition storage position = lpPositions[poolId][positionOwner];
        if (!position.isActive) {
            return this.beforeRemoveLiquidity.selector; // No position to calculate IL for
        }

        // Get current pool state
        (uint160 currentSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Calculate current amounts being removed (simplified)
        // In a real implementation, you'd use exact liquidity math
        uint256 currentAmount0 = params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : 0;
        uint256 currentAmount1 = params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : 0;

        // Calculate impermanent loss using the real algorithm
        uint256 ilBps = ILMath.calculateFullIL(
            position.initialSqrtPrice,
            currentSqrtPriceX96,
            position.initialAmount0,
            position.initialAmount1,
            currentAmount0,
            currentAmount1
        );

        // Pay out compensation if IL exceeds threshold
        if (ilBps > poolConfigs[poolId].ilThresholdBps) {
            uint256 compensation = _calculateCompensation(poolId, ilBps, currentAmount0);

            if (insurancePool[poolId] >= compensation) {
                insurancePool[poolId] -= compensation;
                // In a real implementation, you'd transfer the compensation here
                // TransferHelper.safeTransfer(key.currency0, positionOwner, compensation);
                emit InsurancePayout(poolId, positionOwner, compensation);
            }
        }

        // Mark position as inactive when fully removed
        if (params.liquidityDelta < 0) {
            position.isActive = false;
        }

        // Debug: Emit event to confirm hook callback fired
        emit DebugRemoveLiquidity(poolId, positionOwner, currentSqrtPriceX96, ilBps);

        return this.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice Collect premium on swaps to fund the insurance pool
     */
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        if (!poolConfigs[poolId].isActive) revert PoolNotRegistered();

        // Calculate premium based on swap amount
        uint256 swapAmount =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        uint256 premium = (swapAmount * poolConfigs[poolId].premiumBps) / 10000;

        // Add premium to insurance pool
        insurancePool[poolId] += premium;

        emit PremiumCollected(poolId, tx.origin, premium);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @notice Calculate compensation amount for IL above threshold
     * @param poolId Pool identifier
     * @param ilBps IL in basis points
     * @param positionValue Current position value
     * @return compensation Compensation amount in token0
     */
    function _calculateCompensation(PoolId poolId, uint256 ilBps, uint256 positionValue)
        internal
        view
        returns (uint256 compensation)
    {
        // Calculate compensation based on IL percentage and position size
        uint256 thresholdBps = poolConfigs[poolId].ilThresholdBps;

        // Only compensate for IL above the threshold
        if (ilBps <= thresholdBps) return 0;

        uint256 excessILBps = ilBps - thresholdBps;

        // Compensation = position_value * excess_IL_percentage
        compensation = (positionValue * excessILBps) / 10000;
    }

    /**
     * @notice Get pool configuration
     */
    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory) {
        return poolConfigs[poolId];
    }

    /**
     * @notice Get insurance pool balance
     */
    function getInsuranceBalance(PoolId poolId) external view returns (uint256) {
        return insurancePool[poolId];
    }

    /**
     * @notice Get the current IL for a position (for external queries)
     */
    function getILBps(PoolId, /* poolId */ address /* provider */ ) external pure returns (uint256) {
        return 0; // Placeholder - implement if needed for external queries
    }

    // ============ Required IHooks Interface Functions (Stubs) ============

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }
}
