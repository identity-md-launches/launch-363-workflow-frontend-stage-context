// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Ticket (TIKT)
/// @notice Fixed-supply ERC-20 for the Sepolia swap-lottery launch.
/// @dev 1,000,000,000 TIKT with 18 decimals, minted once to the deployer (the launch factory). There is
/// no owner, no further mint path, no pause and no upgrade. Ticket is a Sepolia test toy: the token and
/// any lottery pot have no value, and nothing here promises a return.
contract Ticket is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor() ERC20("Ticket", "TIKT") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
