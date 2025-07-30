// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ILInsuranceHook} from "../src/ILInsuranceHook.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";

/**
 * @title DeployHook
 * @notice Script to deploy ILInsuranceHook with proper address flags
 */
contract DeployHook is Script {
    // Hook flags we need
    uint160 constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 constant BEFORE_SWAP_FLAG = 1 << 7;
    
    uint160 constant REQUIRED_FLAGS = BEFORE_INITIALIZE_FLAG | 
                                      BEFORE_ADD_LIQUIDITY_FLAG | 
                                      BEFORE_REMOVE_LIQUIDITY_FLAG | 
                                      BEFORE_SWAP_FLAG;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Get deployment parameters from environment
        uint256 premiumBps = vm.envOr("FEE_BPS", uint256(2)); // Default 2 bps
        uint256 thresholdBps = vm.envOr("THRESHOLD_BPS", uint256(100)); // Default 1%
        
        console.log("=== IL Insurance Hook Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Premium BPS:", premiumBps);
        console.log("IL Threshold BPS:", thresholdBps);
        console.log("Required flags:", REQUIRED_FLAGS);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Try to get existing PoolManager address, or deploy new one
        address poolManagerAddr;
        try vm.envAddress("POOL_MANAGER_ADDRESS") returns (address existingPoolManager) {
            poolManagerAddr = existingPoolManager;
            console.log("Using existing PoolManager at:", poolManagerAddr);
        } catch {
            console.log("No POOL_MANAGER_ADDRESS found, deploying new PoolManager...");
            PoolManager poolManager = new PoolManager(deployer);
            poolManagerAddr = address(poolManager);
            console.log("PoolManager deployed at:", poolManagerAddr);
        }
        
        // Mine a salt for the hook address
        bytes memory creationCode = abi.encodePacked(
            type(ILInsuranceHook).creationCode,
            abi.encode(poolManagerAddr, premiumBps, thresholdBps) // constructor args
        );
        
        HookMiner miner = new HookMiner();
        
        // Try to find a valid salt
        (bytes32 salt, address hookAddress) = miner.mineSalt(
            deployer,
            creationCode,
            0, // start salt
            100000 // max iterations
        );
        
        console.log("Found salt:", uint256(salt));
        console.log("Hook address will be:", hookAddress);
        console.log("Address flags:", uint160(hookAddress) & ((1 << 14) - 1));
        
        // Verify the address has required flags
        require(
            (uint160(hookAddress) & REQUIRED_FLAGS) == REQUIRED_FLAGS,
            "Hook address missing required flags"
        );
        
        // Deploy the hook with the mined salt
        ILInsuranceHook hook = new ILInsuranceHook{salt: salt}(
            IPoolManager(poolManagerAddr),
            premiumBps,
            thresholdBps
        );
        
        console.log("ILInsuranceHook deployed at:", address(hook));
        
        // Verify deployment worked correctly
        require(address(hook) == hookAddress, "Hook deployed to wrong address");
        
        // Final verification and summary
        console.log("\n=== Deployment Summary ===");
        console.log("Hook Address:", address(hook));
        console.log("PoolManager Address:", poolManagerAddr);
        console.log("Premium BPS:", premiumBps);
        console.log("IL Threshold BPS:", thresholdBps);
        console.log("Salt Used:", uint256(salt));
        console.log("Address Flags:", uint160(address(hook)) & ((1 << 14) - 1));
        
        // Verify hook configuration
        console.log("\n=== Hook Verification ===");
        console.log("Hook deployed successfully!");
        console.log("Ready for pool creation and testing.");
        
        // Save deployment info to file (for reference)
        string memory deploymentInfo = string(abi.encodePacked(
            "Hook Address: ", vm.toString(address(hook)), "\n",
            "PoolManager: ", vm.toString(poolManagerAddr), "\n",
            "Premium BPS: ", vm.toString(premiumBps), "\n",
            "IL Threshold BPS: ", vm.toString(thresholdBps), "\n",
            "Salt: ", vm.toString(uint256(salt)), "\n",
            "Flags: ", vm.toString(uint160(address(hook)) & ((1 << 14) - 1))
        ));
        
        vm.writeFile("./deployments/latest.txt", deploymentInfo);
        console.log("\nDeployment info saved to ./deployments/latest.txt");
        
        vm.stopBroadcast();
    }
}
