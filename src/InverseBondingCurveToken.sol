// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "openzeppelin/token/ERC20/ERC20.sol";
import "openzeppelin/access/Ownable.sol";
import "openzeppelin/security/Pausable.sol";

/// @title   PeggingToken Contract
/// @author  Sammy
/// @notice  ERC20 token contract of the pegging token, pool contract will mint and burn pegging token
contract InverseBondingCurveToken is ERC20, Ownable, Pausable {
    constructor(address owner_, string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable() {
        transferOwnership(owner_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function mint(address to, uint256 amount) public onlyOwner whenNotPaused {
        _mint(to, amount);
    }

    function burnFrom(address account, uint256 amount) public onlyOwner whenNotPaused {
        _burn(account, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
    }
}
