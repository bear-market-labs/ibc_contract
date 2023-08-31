// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "openzeppelin/token/ERC20/ERC20.sol";
import "openzeppelin/token/ERC20/extensions/ERC20Burnable.sol";
import "openzeppelin/access/AccessControl.sol";
import "openzeppelin/access/Ownable.sol";

/// @title   PeggingToken Contract
/// @author  Sammy
/// @notice  ERC20 token contract of the pegging token, pool contract will mint and burn pegging token
contract InverseBondingCurveToken is ERC20, ERC20Burnable, Ownable {
    constructor(address owner_, string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable() {
        transferOwnership(owner_);
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) public override onlyOwner {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyOwner {
        super.burnFrom(account, amount);
    }
}
