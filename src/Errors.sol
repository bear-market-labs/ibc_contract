// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

error InputAmountTooSmall(uint256 amount);
error ParameterZeroNotAllowed();
error PriceOutOfLimit(uint256 price, uint256 priceLimit);
error ReserveOutOfLimit(uint256 reserve, uint256 reserveLimit);
error UtilizationInvalid(uint256 parameterUtilization);
error InsufficientBalance();
error EmptyAddress();
error FeePercentOutOfRange();
error FailToSend(address recipient);
error InvalidInput();
error Unauthorized();
error InvariantChanged(uint256 invariant, uint256 newInvariant);
