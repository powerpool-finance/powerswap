// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IVaultDepositor2 {
  function add_liquidity(uint256[2] memory _amounts, uint256 _min_mint_amount) external virtual;

  function calc_token_amount(uint256[2] memory _amounts, bool _deposit) external virtual view returns (uint256);
}