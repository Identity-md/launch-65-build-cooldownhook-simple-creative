// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice A plain 18-decimal ERC-20 that mints its whole supply to the deployer. Test-only.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_, 18) {
        _mint(msg.sender, supply);
    }
}
