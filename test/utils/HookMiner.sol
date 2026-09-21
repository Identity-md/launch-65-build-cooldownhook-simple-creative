// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "../../src/HookFlags.sol";

/// @notice Finds a CREATE2 salt that lands a hook on an address carrying exactly the requested permission bits.
/// @dev This is the same search a real deployment performs. With all fourteen bits constrained, one salt in 16,384
/// matches on average, so the bound below fails with probability around e^-12 — effectively never — while still
/// terminating if something is badly wrong (say, the deployer address or init code is not what was expected).
library HookMiner {
    uint256 internal constant MAX_ITERATIONS = 200_000;

    error NoSaltFound();

    /// @param deployer The address that will execute CREATE2 (for `new C{salt: s}(...)`, the calling contract).
    /// @param flags The exact permission bits the address must carry.
    /// @param creationCode `type(C).creationCode`.
    /// @param constructorArgs `abi.encode(...)` of the constructor arguments.
    /// @return hookAddress The address the deployment will land on.
    /// @return salt The salt that gets it there.
    /// @dev Addresses that already hold code are skipped: the same deployer, init code and salt always produce
    /// the same address, so a second deployment of an identical hook must move on to the next matching salt
    /// rather than collide with the first.
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
            salt = bytes32(i);
            hookAddress =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if (HookFlags.matches(hookAddress, flags) && hookAddress.code.length == 0) return (hookAddress, salt);
        }
        revert NoSaltFound();
    }
}
