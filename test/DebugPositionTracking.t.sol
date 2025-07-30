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
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title DebugPositionTrackingTest
 * @notice Debug test to understand position tracking issues
 */
contract DebugPositionTrackingTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Test contracts
    ILInsuranceHook hook;
    PoolManager poolManager;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    
    // Test tokens
    Currency currency0;
    Currency currency1;
    
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

    function setUp() public {
        address deployer = address(0x3);
        
        // Deploy PoolManager
        poolManager = new PoolManager(deployer);
        
        // Deploy router
        modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);
        
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
        
        // Approve routers
        IERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        
        // Initialize the pool (this automatically registers it with the hook)
        vm.startPrank(deployer);
        poolManager.initialize(key, SQRT_PRICE_1_1);
        vm.stopPrank();
        
        console.log("=== Setup Complete ===");
        console.log("Hook address:", address(hook));
        console.log("Router address:", address(modifyLiquidityRouter));
        console.log("Pool ID:", uint256(PoolId.unwrap(poolId)));
        console.log("Initial sqrt price:", SQRT_PRICE_1_1);
    }

    function testDebugPositionTracking() public {
        console.log("\n=== Starting Position Tracking Debug ===");
        
        // Check pool state before adding liquidity
        (uint160 currentSqrtPrice,,,) = StateLibrary.getSlot0(poolManager, poolId);
        console.log("Current pool sqrt price:", currentSqrtPrice);
        
        // Check pool config
        (uint256 premiumBps, uint256 ilThresholdBps, bool isActive) = hook.poolConfigs(poolId);
        console.log("Pool config - Premium BPS:", premiumBps);
        console.log("Pool config - IL Threshold BPS:", ilThresholdBps);
        console.log("Pool config - Is Active:", isActive);
        
        // Check position before adding liquidity
        (uint160 beforeSqrtPrice, uint256 beforeAmount0, uint256 beforeAmount1, uint256 beforeTimestamp, bool beforeActive) = 
            hook.lpPositions(poolId, address(modifyLiquidityRouter));
        console.log("\nBefore adding liquidity:");
        console.log("  Position sqrt price:", beforeSqrtPrice);
        console.log("  Position amount0:", beforeAmount0);
        console.log("  Position amount1:", beforeAmount1);
        console.log("  Position timestamp:", beforeTimestamp);
        console.log("  Position active:", beforeActive);
        
        console.log("\n=== Adding Liquidity ===");
        
        // Add liquidity
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
        
        console.log("Liquidity added successfully");
        
        // Check position after adding liquidity
        (uint160 afterSqrtPrice, uint256 afterAmount0, uint256 afterAmount1, uint256 afterTimestamp, bool afterActive) = 
            hook.lpPositions(poolId, address(modifyLiquidityRouter));
        console.log("\nAfter adding liquidity:");
        console.log("  Position sqrt price:", afterSqrtPrice);
        console.log("  Position amount0:", afterAmount0);
        console.log("  Position amount1:", afterAmount1);
        console.log("  Position timestamp:", afterTimestamp);
        console.log("  Position active:", afterActive);
        
        // Verify the position was recorded
        if (afterSqrtPrice > 0) {
            console.log("\nSUCCESS: Position tracking is working!");
        } else {
            console.log("\nFAILURE: Position not recorded properly");
        }
        
        // Check current pool state again
        (uint160 finalSqrtPrice,,,) = StateLibrary.getSlot0(poolManager, poolId);
        console.log("Final pool sqrt price:", finalSqrtPrice);
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
