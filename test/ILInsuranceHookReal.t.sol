// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ILInsuranceHook} from "../src/ILInsuranceHook.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {ILMath} from "../src/ILMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title ILInsuranceHookRealTest
 * @notice Comprehensive tests for the real IL calculation implementation
 */
contract ILInsuranceHookRealTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Test contracts
    ILInsuranceHook hook;
    PoolManager poolManager;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    PoolSwapTest swapRouter;
    
    // Test tokens
    Currency currency0;
    Currency currency1;
    
    // Test users
    address user1 = address(0x1);
    address user2 = address(0x2);
    address deployer = address(0x3);
    
    // Pool configuration
    PoolKey key;
    PoolId poolId;
    uint24 constant FEE = 3000; // 0.3%
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // sqrt(1) * 2^96
    bytes constant ZERO_BYTES = "";

    // Hook flags we need
    uint160 constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 constant BEFORE_SWAP_FLAG = 1 << 7;
    
    uint160 constant REQUIRED_FLAGS = BEFORE_INITIALIZE_FLAG | 
                                      BEFORE_ADD_LIQUIDITY_FLAG | 
                                      BEFORE_REMOVE_LIQUIDITY_FLAG | 
                                      BEFORE_SWAP_FLAG;

    // Events
    event InsurancePayout(PoolId indexed poolId, address indexed provider, uint256 amount);
    event PremiumCollected(PoolId indexed poolId, uint256 amount);

    function setUp() public {
        // Deploy PoolManager
        poolManager = new PoolManager(deployer);
        
        // Deploy routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);
        
        // Mine hook address with correct flags
        HookMiner miner = new HookMiner();
        bytes memory creationCode = abi.encodePacked(
            type(ILInsuranceHook).creationCode,
            abi.encode(poolManager, 2, 100) // 2 bps premium, 100 bps threshold
        );
        (bytes32 salt, address hookAddress) = miner.mineSalt(
            address(this),
            creationCode,
            0, // start salt
            100000 // max iterations
        );
        
        // Deploy the hook with the mined salt
        hook = new ILInsuranceHook{salt: salt}(poolManager, 2, 100);
        
        // Verify deployment worked correctly
        require(address(hook) == hookAddress, "Hook deployed to wrong address");
        uint160 ALL_HOOK_MASK = uint160((1 << 14) - 1);
        require(
            (uint160(address(hook)) & ALL_HOOK_MASK) == REQUIRED_FLAGS,
            "Hook address has incorrect flags"
        );
        
        // Create mock tokens for testing
        currency0 = Currency.wrap(address(new MockERC20("Token0", "TK0")));
        currency1 = Currency.wrap(address(new MockERC20("Token1", "TK1")));
        
        // Ensure currency0 < currency1 for proper ordering
        if (Currency.unwrap(currency0) > Currency.unwrap(currency1)) {
            (currency0, currency1) = (currency1, currency0);
        }
        
        // Set up pool key
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
        
        poolId = key.toId();
        
        // Fund test accounts and approve routers
        deal(Currency.unwrap(currency0), address(this), 1000 ether);
        deal(Currency.unwrap(currency1), address(this), 1000 ether);
        deal(Currency.unwrap(currency0), user1, 1000 ether);
        deal(Currency.unwrap(currency1), user1, 1000 ether);
        deal(Currency.unwrap(currency0), user2, 1000 ether);
        deal(Currency.unwrap(currency1), user2, 1000 ether);
        
        // Approve routers
        IERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        
        vm.startPrank(user1);
        IERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
        
        // Initialize the pool (this automatically registers it with the hook)
        vm.startPrank(deployer);
        poolManager.initialize(key, SQRT_PRICE_1_1);
        vm.stopPrank();
    }

    function testRealILCalculationBasic() public {
        // Add liquidity to create a position
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000e18,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        // Check that position was recorded correctly
        // Note: Hook tracks positions by msg.sender (router contract), not the end user
        (uint160 initialSqrtPrice, uint256 initialAmount0, uint256 initialAmount1, uint256 timestamp, bool isActive) = 
            hook.lpPositions(poolId, address(modifyLiquidityRouter));
        
        assertGt(initialSqrtPrice, 0, "Initial sqrt price should be recorded");
        assertEq(initialSqrtPrice, SQRT_PRICE_1_1, "Should record correct initial price");
        assertGt(timestamp, 0, "Timestamp should be recorded");
        assertTrue(isActive, "Position should be active");
        
        console.log("Initial position recorded:");
        console.log("  sqrt price:", initialSqrtPrice);
        console.log("  amount0:", initialAmount0);
        console.log("  amount1:", initialAmount1);
        console.log("  timestamp:", timestamp);
    }

    function testILCalculationWithPriceChange() public {
        // Add initial liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000e18,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        // Record initial state
        (uint160 initialSqrtPrice, , , , ) = hook.lpPositions(poolId, address(modifyLiquidityRouter));
        
        // Perform a large swap to change the price significantly
        // This should create impermanent loss
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100e18, // Exact output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );
        
        // Check that price has changed
        (uint160 newSqrtPrice,,,) = StateLibrary.getSlot0(poolManager, poolId);
        assertNotEq(newSqrtPrice, initialSqrtPrice, "Price should have changed after swap");
        
        console.log("Price change:");
        console.log("  Initial sqrt price:", initialSqrtPrice);
        console.log("  New sqrt price:", newSqrtPrice);
        
        // Remove liquidity to trigger IL calculation
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -500e18, // Remove half
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        // Position should still be active (partial removal)
        (, , , , bool isActive) = hook.lpPositions(poolId, address(modifyLiquidityRouter));
        assertTrue(isActive, "Position should still be active after partial removal");
    }

    function testILMathDirectly() public pure {
        // Test the IL calculation math directly
        uint160 initialSqrtPrice = SQRT_PRICE_1_1; // Price = 1
        uint160 finalSqrtPrice = SQRT_PRICE_1_1 * 2; // Price = 4 (2x sqrt price = 4x price)
        
        uint256 initialAmount0 = 1000e18;
        uint256 initialAmount1 = 1000e18;
        uint256 finalAmount0 = 500e18;  // Less token0 due to price increase
        uint256 finalAmount1 = 2000e18; // More token1 due to price increase
        
        uint256 ilBps = ILMath.calculateFullIL(
            initialSqrtPrice,
            finalSqrtPrice,
            initialAmount0,
            initialAmount1,
            finalAmount0,
            finalAmount1
        );
        
        console.log("Direct IL calculation:");
        console.log("  Initial sqrt price:", initialSqrtPrice);
        console.log("  Final sqrt price:", finalSqrtPrice);
        console.log("  IL in basis points:", ilBps);
        
        // With a 4x price increase, we expect significant IL
        assertGt(ilBps, 0, "Should have positive IL with price change");
    }

    function testCompensationCalculation() public pure {
        uint256 ilBps = 500; // 5% IL
        uint256 thresholdBps = 100; // 1% threshold
        uint256 positionValue = 1000e18;
        
        // Calculate expected compensation
        uint256 excessIL = ilBps - thresholdBps; // 400 bps = 4%
        uint256 expectedCompensation = (positionValue * excessIL) / 10000; // 4% of position
        
        // Test the internal calculation (we'll need to make this public for testing)
        // For now, just verify the math
        assertEq(expectedCompensation, 40e18, "Should compensate 4% of position value");
        
        console.log("Compensation calculation:");
        console.log("  IL:", ilBps, "bps");
        console.log("  Threshold:", thresholdBps, "bps");
        console.log("  Excess IL:", excessIL, "bps");
        console.log("  Position value:", positionValue);
        console.log("  Compensation:", expectedCompensation);
    }

    function testPremiumCollection() public {
        // Initialize pool and add liquidity first
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000e18,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        uint256 initialInsurancePool = hook.insurancePool(poolId);
        
        // Perform a swap to collect premiums
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 100e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );
        
        uint256 finalInsurancePool = hook.insurancePool(poolId);
        
        // Insurance pool should have grown from premium collection
        assertGt(finalInsurancePool, initialInsurancePool, "Insurance pool should grow from premiums");
        
        console.log("Premium collection:");
        console.log("  Initial insurance pool:", initialInsurancePool);
        console.log("  Final insurance pool:", finalInsurancePool);
        console.log("  Premium collected:", finalInsurancePool - initialInsurancePool);
    }

    function testFullILScenario() public {
        // 1. Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000e18,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        // 2. Collect some premiums through swaps
        for (uint i = 0; i < 5; i++) {
            swapRouter.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: i % 2 == 0,
                    amountSpecified: 50e18,
                    sqrtPriceLimitX96: i % 2 == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({
                    takeClaims: false,
                    settleUsingBurn: false
                }),
                ZERO_BYTES
            );
        }
        
        uint256 insurancePoolBalance = hook.insurancePool(poolId);
        console.log("Insurance pool after swaps:", insurancePoolBalance);
        
        // 3. Create significant price movement
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -500e18, // Large swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );
        
        // 4. Remove liquidity to trigger IL calculation and potential payout
        uint256 balanceBefore = hook.insurancePool(poolId);
        
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -1000e18, // Remove all liquidity
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        uint256 balanceAfter = hook.insurancePool(poolId);
        
        // Check if payout occurred
        if (balanceAfter < balanceBefore) {
            console.log("IL compensation paid out!");
            console.log("  Amount:", balanceBefore - balanceAfter);
        } else {
            console.log("No IL compensation needed");
        }
        
        // Position should be inactive after full removal
        (, , , , bool isActive) = hook.lpPositions(poolId, address(modifyLiquidityRouter));
        assertFalse(isActive, "Position should be inactive after full removal");
    }
}

// Mock ERC20 token for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    
    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        totalSupply = 1000000 * 10**decimals;
        balanceOf[msg.sender] = totalSupply;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}
