// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "openzeppelin/token/ERC20/ERC20.sol";

import "forge-std/console2.sol";

contract WethToken is ERC20 {
    constructor() ERC20("WETH", "WETH") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) public {
        // uint256 balance = balanceOf(msg.sender);
        require(balanceOf(msg.sender) >= amount, "Insufficient Balance");

        _burn(msg.sender, amount);

        (bool sent,) = msg.sender.call{value: amount}("");
        require(sent, "Fail to send Ether");
    }
}

contract ReserveToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
