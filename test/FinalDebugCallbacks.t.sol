// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {Test, console, Vm} from "forge-std/Test.sol";
import {ILInsuranceHook} from "../src/ILInsuranceHook.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

/**
 * @title FinalDebugCallbacksTest
 * @notice Final test to verify hook callbacks fire - using existing infrastructure
 */
contract FinalDebugCallbacksTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolManager poolManager;
    ILInsuranceHook hook;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    PoolSwapTest swapRouter;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;

    address constant DEPLOYER = address(0x1);
    address constant LP_PROVIDER = address(0x2);

    function setUp() public {
        // Deploy PoolManager
        poolManager = new PoolManager(DEPLOYER);

        // Deploy routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);

        // Use simple addresses as mock currencies (common pattern in v4 tests)
        currency0 = Currency.wrap(address(0x1000));
        currency1 = Currency.wrap(address(0x2000));

        // Mine hook address with correct flags
        HookMiner miner = new HookMiner();
        bytes memory creationCode =
            abi.encodePacked(type(ILInsuranceHook).creationCode, abi.encode(poolManager, 2, 100));
        (bytes32 salt,) = miner.mineSalt(address(this), creationCode, 0, 100000);

        // Deploy hook
        hook = new ILInsuranceHook{salt: salt}(poolManager, 2, 100);

        // Create pool key
        poolKey = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: hook});
        poolId = poolKey.toId();

        // Initialize pool
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        poolManager.initialize(poolKey, initialSqrtPriceX96);

        console.log("=== Setup Complete ===");
        console.log("Hook address:", address(hook));
        console.log("Pool ID:", uint256(PoolId.unwrap(poolId)));
        console.log("ModifyLiquidity Router:", address(modifyLiquidityRouter));
    }

    /**
     * @notice Test if hook callbacks fire by checking for debug events
     */
    function testDebugHookCallbacks() public {
        console.log("\n=== Testing Hook Callbacks ===");

        // Mock currency transfers (since we're using mock addresses)
        vm.mockCall(
            Currency.unwrap(currency0),
            abi.encodeWithSignature("transferFrom(address,address,uint256)"),
            abi.encode(true)
        );
        vm.mockCall(
            Currency.unwrap(currency1),
            abi.encodeWithSignature("transferFrom(address,address,uint256)"),
            abi.encode(true)
        );
        vm.mockCall(Currency.unwrap(currency0), abi.encodeWithSignature("transfer(address,uint256)"), abi.encode(true));
        vm.mockCall(Currency.unwrap(currency1), abi.encodeWithSignature("transfer(address,uint256)"), abi.encode(true));

        // Set up liquidity parameters
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 1000e18,
            salt: bytes32(0)
        });

        console.log("=== Test 1: Add Liquidity ===");
        console.log("Calling modifyLiquidity with positive liquidityDelta...");
        console.log("Expected: DebugAddLiquidity event should be emitted");

        vm.startPrank(LP_PROVIDER);

        // Record logs to check for our debug events
        vm.recordLogs();

        try modifyLiquidityRouter.modifyLiquidity(poolKey, params, bytes("")) {
            console.log("SUCCESS: modifyLiquidity (add) completed");
        } catch Error(string memory reason) {
            console.log("FAILED: modifyLiquidity (add) failed:", reason);
        } catch (bytes memory) {
            console.log("FAILED: modifyLiquidity (add) failed with low-level error");
        }

        // Check recorded logs for our debug event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool addLiquidityEventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            // Check if this is our DebugAddLiquidity event
            // Event signature: DebugAddLiquidity(PoolId indexed poolId, address indexed sender, uint160 sqrtPrice, uint256 amount0, uint256 amount1)
            if (
                logs[i].topics.length >= 3
                    && logs[i].topics[0] == keccak256("DebugAddLiquidity(bytes32,address,uint160,uint256,uint256)")
            ) {
                addLiquidityEventFound = true;
                console.log("SUCCESS: DebugAddLiquidity event found!");
                console.log("Pool ID from event:", uint256(bytes32(logs[i].topics[1])));
                console.log("Sender from event:", address(uint160(uint256(logs[i].topics[2]))));
                break;
            }
        }

        if (!addLiquidityEventFound) {
            console.log("CRITICAL: DebugAddLiquidity event NOT found!");
            console.log("This means beforeAddLiquidity callback is NOT firing!");
        }

        console.log("\n=== Test 2: Remove Liquidity ===");
        console.log("Calling modifyLiquidity with negative liquidityDelta...");
        console.log("Expected: DebugRemoveLiquidity event should be emitted");

        // Now test remove liquidity
        params.liquidityDelta = -1000e18;

        vm.recordLogs();

        try modifyLiquidityRouter.modifyLiquidity(poolKey, params, bytes("")) {
            console.log("SUCCESS: modifyLiquidity (remove) completed");
        } catch Error(string memory reason) {
            console.log("FAILED: modifyLiquidity (remove) failed:", reason);
        } catch (bytes memory) {
            console.log("FAILED: modifyLiquidity (remove) failed with low-level error");
        }

        // Check for remove liquidity debug event
        logs = vm.getRecordedLogs();
        bool removeLiquidityEventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics.length >= 3
                    && logs[i].topics[0] == keccak256("DebugRemoveLiquidity(bytes32,address,uint160,uint256)")
            ) {
                removeLiquidityEventFound = true;
                console.log("SUCCESS: DebugRemoveLiquidity event found!");
                break;
            }
        }

        if (!removeLiquidityEventFound) {
            console.log("CRITICAL: DebugRemoveLiquidity event NOT found!");
            console.log("This means beforeRemoveLiquidity callback is NOT firing!");
        }

        vm.stopPrank();

        console.log("\n=== Test 3: Swap (Known Working) ===");
        console.log("Testing swap to confirm beforeSwap callback works...");

        vm.recordLogs();

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        try swapRouter.swap(
            poolKey, swapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), bytes("")
        ) {
            console.log("SUCCESS: Swap completed");
        } catch Error(string memory reason) {
            console.log("FAILED: Swap failed:", reason);
        } catch (bytes memory) {
            console.log("FAILED: Swap failed with low-level error");
        }

        // Check for premium collected event (from beforeSwap)
        logs = vm.getRecordedLogs();
        bool premiumEventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics.length >= 3
                    && logs[i].topics[0] == keccak256("PremiumCollected(bytes32,address,uint256)")
            ) {
                premiumEventFound = true;
                console.log("SUCCESS: PremiumCollected event found (beforeSwap works)!");
                break;
            }
        }

        if (!premiumEventFound) {
            console.log("UNEXPECTED: PremiumCollected event NOT found!");
            console.log("This suggests even beforeSwap might not be working in this test setup.");
        }

        console.log("\n=== Final Analysis ===");
        console.log("Add liquidity callback working:", addLiquidityEventFound);
        console.log("Remove liquidity callback working:", removeLiquidityEventFound);
        console.log("Swap callback working:", premiumEventFound);

        if (!addLiquidityEventFound || !removeLiquidityEventFound) {
            console.log("\nCONCLUSION: Position tracking callbacks are NOT firing!");
            console.log("This confirms the issue is with hook callback invocation for liquidity operations.");
            console.log("The hook logic itself is correct, but callbacks aren't being triggered.");
        } else {
            console.log("\nCONCLUSION: All callbacks working! Hook is fully functional!");
        }
    }
}
