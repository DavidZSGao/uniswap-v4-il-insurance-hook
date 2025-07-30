// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ILInsuranceHook} from "../src/ILInsuranceHook.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/**
 * @title DebugHookFlagsTest
 * @notice Debug test to verify hook address flags are correct
 */
contract DebugHookFlagsTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Hook flags from Hooks library
    uint160 constant BEFORE_INITIALIZE_FLAG = 1 << 13; // 8192
    uint160 constant AFTER_INITIALIZE_FLAG = 1 << 12; // 4096
    uint160 constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11; // 2048
    uint160 constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 10; // 1024
    uint160 constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9; // 512
    uint160 constant AFTER_REMOVE_LIQUIDITY_FLAG = 1 << 8; // 256
    uint160 constant BEFORE_SWAP_FLAG = 1 << 7; // 128
    uint160 constant AFTER_SWAP_FLAG = 1 << 6; // 64

    uint160 constant ALL_HOOK_MASK = uint160((1 << 14) - 1); // 16383

    function testHookFlagsDebug() public {
        address deployer = address(0x3);

        // Deploy PoolManager
        PoolManager poolManager = new PoolManager(deployer);

        // Mine hook address with correct flags
        HookMiner miner = new HookMiner();
        bytes memory creationCode =
            abi.encodePacked(type(ILInsuranceHook).creationCode, abi.encode(poolManager, 2, 100));
        (bytes32 salt, address hookAddress) = miner.mineSalt(address(this), creationCode, 0, 100000);

        console.log("=== Hook Address Analysis ===");
        console.log("Hook address:", hookAddress);
        console.log("Hook address as uint160:", uint160(hookAddress));

        // Extract the flags from the hook address
        uint160 actualFlags = uint160(hookAddress) & ALL_HOOK_MASK;
        console.log("Actual flags in address:", actualFlags);

        // Calculate what flags we need
        uint160 requiredFlags =
            BEFORE_INITIALIZE_FLAG | BEFORE_ADD_LIQUIDITY_FLAG | BEFORE_REMOVE_LIQUIDITY_FLAG | BEFORE_SWAP_FLAG;
        console.log("Required flags:", requiredFlags);

        // Check individual flags
        console.log("\n=== Individual Flag Analysis ===");
        console.log("BEFORE_INITIALIZE_FLAG (8192):", BEFORE_INITIALIZE_FLAG);
        console.log("Has BEFORE_INITIALIZE:", (actualFlags & BEFORE_INITIALIZE_FLAG) != 0);

        console.log("BEFORE_ADD_LIQUIDITY_FLAG (2048):", BEFORE_ADD_LIQUIDITY_FLAG);
        console.log("Has BEFORE_ADD_LIQUIDITY:", (actualFlags & BEFORE_ADD_LIQUIDITY_FLAG) != 0);

        console.log("BEFORE_REMOVE_LIQUIDITY_FLAG (512):", BEFORE_REMOVE_LIQUIDITY_FLAG);
        console.log("Has BEFORE_REMOVE_LIQUIDITY:", (actualFlags & BEFORE_REMOVE_LIQUIDITY_FLAG) != 0);

        console.log("BEFORE_SWAP_FLAG (128):", BEFORE_SWAP_FLAG);
        console.log("Has BEFORE_SWAP:", (actualFlags & BEFORE_SWAP_FLAG) != 0);

        // Verify flags match exactly
        bool flagsMatch = actualFlags == requiredFlags;
        console.log("\nFlags match exactly:", flagsMatch);

        if (!flagsMatch) {
            console.log("ERROR: Hook address flags don't match requirements!");
            console.log("This explains why hook callbacks aren't firing.");
        } else {
            console.log("SUCCESS: Hook address has correct flags.");
        }

        // Deploy the hook and test validation
        ILInsuranceHook hook = new ILInsuranceHook{salt: salt}(poolManager, 2, 100);
        console.log("\nHook deployed successfully at:", address(hook));

        console.log("Hook validation completed in constructor");
    }
}
