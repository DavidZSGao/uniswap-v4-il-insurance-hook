// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/**
 * @title HookMiner
 * @notice Utility contract to mine hook addresses with correct flags
 * @dev Used to find a salt that produces a hook address with the required flags
 */
contract HookMiner {
    // Hook flags we need for ILInsuranceHook
    uint160 constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 constant BEFORE_SWAP_FLAG = 1 << 7;
    
    // Combined flags for our hook
    uint160 constant REQUIRED_FLAGS = BEFORE_INITIALIZE_FLAG | 
                                      BEFORE_ADD_LIQUIDITY_FLAG | 
                                      BEFORE_REMOVE_LIQUIDITY_FLAG | 
                                      BEFORE_SWAP_FLAG;

    /**
     * @notice Compute the address for a hook deployment with given salt
     * @param deployer The address that will deploy the hook
     * @param salt The salt to use for CREATE2
     * @param creationCode The creation code of the hook contract
     * @return hookAddress The computed address
     */
    function computeHookAddress(
        address deployer,
        bytes32 salt,
        bytes memory creationCode
    ) external pure returns (address hookAddress) {
        hookAddress = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            deployer,
                            salt,
                            keccak256(creationCode)
                        )
                    )
                )
            )
        );
    }

    /**
     * @notice Check if an address has the required hook flags
     * @param hookAddress The address to check
     * @return hasFlags True if the address has all required flags
     */
    function hasRequiredFlags(address hookAddress) external pure returns (bool hasFlags) {
        uint160 addr = uint160(hookAddress);
        uint160 ALL_HOOK_MASK = uint160((1 << 14) - 1);
        // Check that the address has exactly the required flags and no extra flags
        hasFlags = (addr & ALL_HOOK_MASK) == REQUIRED_FLAGS;
    }

    /**
     * @notice Mine a salt that produces a valid hook address
     * @param deployer The address that will deploy the hook
     * @param creationCode The creation code of the hook contract
     * @param startSalt Starting salt value for mining
     * @param maxIterations Maximum iterations to try
     * @return salt The found salt
     * @return hookAddress The computed hook address
     */
    function mineSalt(
        address deployer,
        bytes memory creationCode,
        uint256 startSalt,
        uint256 maxIterations
    ) external pure returns (bytes32 salt, address hookAddress) {
        for (uint256 i = 0; i < maxIterations; i++) {
            salt = bytes32(startSalt + i);
            hookAddress = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                deployer,
                                salt,
                                keccak256(creationCode)
                            )
                        )
                    )
                )
            );
            
            uint160 ALL_HOOK_MASK = uint160((1 << 14) - 1);
            if ((uint160(hookAddress) & ALL_HOOK_MASK) == REQUIRED_FLAGS) {
                return (salt, hookAddress);
            }
        }
        
        revert("Salt not found");
    }
}
