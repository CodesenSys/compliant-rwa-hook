// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @title  MockERC20
/// @author CodesenSys (https://codesensys.com)
/// @notice Mintable ERC-20 for testnet deployments. Do not use in production.
contract MockERC20 is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    /// @notice Open mint — testnet only. Anyone can mint.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
