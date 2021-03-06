pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../interfaces/IVault.sol";

abstract contract ERC20Detailed is IERC20 {
  string private _name;
  string private _symbol;
  uint8 private _decimals;

  constructor (string memory name, string memory symbol, uint8 decimals) public {
    _name = name;
    _symbol = symbol;
    _decimals = decimals;
  }
  function name() public view returns (string memory) {
    return _name;
  }
  function symbol() public view returns (string memory) {
    return _symbol;
  }
  function decimals() public view returns (uint8) {
    return _decimals;
  }
}

interface Controller {
  function withdraw(address, uint) external;
  function balanceOf(address) external view returns (uint);
  function earn(address, uint) external;
}

contract MockYearnVaultV1 is ERC20 {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  IERC20 public token;

  uint public min = 9500;
  uint public constant max = 10000;

  address public governance;
  address public controller;

  constructor (address _token, address _controller) public ERC20(
    string(abi.encodePacked("yearn ", ERC20Detailed(_token).name())),
    string(abi.encodePacked("y", ERC20Detailed(_token).symbol()))
  ) {
    token = IERC20(_token);
    governance = msg.sender;
    controller = _controller;
  }

  function totalAssets() public view returns (uint) {
    return token.balanceOf(address(this))
    .add(Controller(controller).balanceOf(address(token)));
  }

  function setMin(uint _min) external {
    require(msg.sender == governance, "!governance");
    min = _min;
  }

  function setGovernance(address _governance) public {
    require(msg.sender == governance, "!governance");
    governance = _governance;
  }

  function setController(address _controller) public {
    require(msg.sender == governance, "!governance");
    controller = _controller;
  }

  // Custom logic in here for how much the vault allows to be borrowed
  // Sets minimum required on-hand to keep small withdrawals cheap
  function available() public view returns (uint) {
    return token.balanceOf(address(this)).mul(min).div(max);
  }

  function earn() public {
    uint _bal = available();
    token.safeTransfer(controller, _bal);
    Controller(controller).earn(address(token), _bal);
  }

  function depositAll() external {
    deposit(token.balanceOf(msg.sender));
  }

  function deposit(uint _amount) public {
    uint _pool = totalAssets();
    uint _before = token.balanceOf(address(this));
    token.safeTransferFrom(msg.sender, address(this), _amount);
    uint _after = token.balanceOf(address(this));
    _amount = _after.sub(_before); // Additional check for deflationary tokens
    uint shares = 0;
    if (totalSupply() == 0) {
      shares = _amount;
    } else {
      shares = (_amount.mul(totalSupply())).div(_pool);
    }
    _mint(msg.sender, shares);
  }

  function withdrawAll() external {
    withdraw(balanceOf(msg.sender));
  }


  // Used to swap any borrowed reserve over the debt limit to liquidate to 'token'
  function harvest(address reserve, uint amount) external {
    require(msg.sender == controller, "!controller");
    require(reserve != address(token), "token");
    IERC20(reserve).safeTransfer(controller, amount);
  }

  // No rebalance implementation for lower fees and faster swaps
  function withdraw(uint _shares) public {
    uint r = (totalAssets().mul(_shares)).div(totalSupply());
    _burn(msg.sender, _shares);

    // Check balance
    uint b = token.balanceOf(address(this));
    if (b < r) {
      uint _withdraw = r.sub(b);
      Controller(controller).withdraw(address(token), _withdraw);
      uint _after = token.balanceOf(address(this));
      uint _diff = _after.sub(b);
      if (_diff < _withdraw) {
        r = b.add(_diff);
      }
    }

    token.safeTransfer(msg.sender, r);
  }

  function pricePerShare() public view returns (uint) {
    return totalAssets().mul(1e18).div(totalSupply());
  }
}
