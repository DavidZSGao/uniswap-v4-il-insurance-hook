// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Gaozhesi
// IL Math Library - Original Implementation
// Created: July 2025
pragma solidity ^0.8.26;

/**
 * @title ILMath
 * @notice Mathematical utilities for impermanent loss calculations
 * @dev Provides sqrt and other math functions needed for IL computation
 */
library ILMath {
    /**
     * @notice Babylonian square root implementation
     * @param x The number to find square root of
     * @return y The square root of x
     */
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /**
     * @notice Calculate price ratio from sqrt prices
     * @param sqrtPriceX96_1 Current sqrt price (X96 format)
     * @param sqrtPriceX96_0 Initial sqrt price (X96 format)
     * @return priceRatio Price ratio scaled by 1e18
     */
    function calculatePriceRatio(
        uint160 sqrtPriceX96_1,
        uint160 sqrtPriceX96_0
    ) internal pure returns (uint256 priceRatio) {
        // priceRatio = (sqrtP1 / sqrtP0)^2
        // Scale to avoid precision loss
        uint256 sqrtP1 = uint256(sqrtPriceX96_1);
        uint256 sqrtP0 = uint256(sqrtPriceX96_0);
        
        // Calculate (sqrtP1 * sqrtP1) / (sqrtP0 * sqrtP0) with proper scaling
        priceRatio = (sqrtP1 * sqrtP1 * 1e18) / (sqrtP0 * sqrtP0);
    }

    /**
     * @notice Calculate HODL value in token0 terms
     * @param priceRatio Current price ratio (scaled by 1e18)
     * @param amount0 Initial amount of token0
     * @param amount1 Initial amount of token1
     * @return hodlValue HODL value in token0 terms (scaled by 1e18)
     */
    function calculateHodlValue(
        uint256 priceRatio,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint256 hodlValue) {
        // V_HODL = sqrt(P1/P0) * Q0 + sqrt(P0/P1) * R0
        uint256 sqrtRatio = sqrt(priceRatio);
        uint256 invSqrtRatio = (1e18 * 1e18) / sqrtRatio;
        
        hodlValue = (sqrtRatio * amount0) / 1e18 + (invSqrtRatio * amount1) / 1e18;
    }

    /**
     * @notice Calculate LP value in token0 terms
     * @param priceRatio Current price ratio (scaled by 1e18)
     * @param amount0 Current amount of token0 from LP position
     * @param amount1 Current amount of token1 from LP position
     * @return lpValue LP value in token0 terms (scaled by 1e18)
     */
    function calculateLpValue(
        uint256 priceRatio,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint256 lpValue) {
        // V_LP = Q1 + (P1/P0) * R1
        lpValue = amount0 + (priceRatio * amount1) / 1e18;
    }

    /**
     * @notice Calculate impermanent loss in basis points
     * @param hodlValue HODL value in token0 terms
     * @param lpValue LP value in token0 terms
     * @return ilBps Impermanent loss in basis points
     */
    function calculateILBps(
        uint256 hodlValue,
        uint256 lpValue
    ) internal pure returns (uint256 ilBps) {
        if (hodlValue == 0) return 0;
        if (lpValue >= hodlValue) return 0; // No IL if LP value >= HODL value
        
        ilBps = ((hodlValue - lpValue) * 10000) / hodlValue;
    }

    /**
     * @notice Complete IL calculation from sqrt prices and amounts
     * @param sqrtPriceX96_0 Initial sqrt price
     * @param sqrtPriceX96_1 Current sqrt price
     * @param initialAmount0 Initial token0 amount
     * @param initialAmount1 Initial token1 amount
     * @param currentAmount0 Current token0 amount
     * @param currentAmount1 Current token1 amount
     * @return ilBps Impermanent loss in basis points
     */
    function calculateFullIL(
        uint160 sqrtPriceX96_0,
        uint160 sqrtPriceX96_1,
        uint256 initialAmount0,
        uint256 initialAmount1,
        uint256 currentAmount0,
        uint256 currentAmount1
    ) internal pure returns (uint256 ilBps) {
        uint256 priceRatio = calculatePriceRatio(sqrtPriceX96_1, sqrtPriceX96_0);
        uint256 hodlValue = calculateHodlValue(priceRatio, initialAmount0, initialAmount1);
        uint256 lpValue = calculateLpValue(priceRatio, currentAmount0, currentAmount1);
        
        return calculateILBps(hodlValue, lpValue);
    }
}
