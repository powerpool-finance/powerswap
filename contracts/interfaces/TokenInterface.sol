// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract TokenInterface is IERC20 {
  function deposit() public payable virtual;

  function withdraw(uint256) public virtual;
}
