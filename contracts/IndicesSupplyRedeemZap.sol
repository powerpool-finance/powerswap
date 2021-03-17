// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@powerpool/poweroracle/contracts/interfaces/IPowerPoke.sol";
import "./interfaces/PowerIndexPoolInterface.sol";
import "./interfaces/TokenInterface.sol";
import "./Erc20PiptSwap.sol";
import "hardhat/console.sol";
import "./interfaces/IVaultDepositor2.sol";
import "./interfaces/IVaultDepositor3.sol";
import "./interfaces/IVaultDepositor4.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultRegistry.sol";

contract IndicesSupplyRedeemZap is OwnableUpgradeSafe {
  using SafeMath for uint256;

  event NewRound(uint256 indexed id, uint256 createdAt);
  event InitRoundKey(
    uint256 indexed id,
    bytes32 indexed key,
    address indexed pool,
    address inputToken,
    address outputToken
  );
  event SetFee(uint256 fee);

  uint256 internal constant COMPENSATION_PLAN_1_ID = 1;
  address public constant ETH = 0x0000000000000000000000000000000000000001;

  IERC20 public immutable usdc;
  IPowerPoke public immutable powerPoke;

  enum PoolType { NULL, PIPT, VAULT }

  mapping(address => PoolType) public poolType;
  mapping(address => address) public poolPiptSwap;
  mapping(address => address[]) public poolTokens;

  struct VaultConfig {
    uint256 depositorLength;
    uint256 depositorIndex;
    address depositor;
    address lpToken;
    address vaultRegistry;
  }
  mapping(address => VaultConfig) public vaultConfig;

  uint256 public roundCounter;
  uint256 public lastRoundCreatedAt;
  uint256 public roundPeriod;

  uint256 public oddEth;

  address public feeReceiver;
  mapping(address => uint256) public feeByToken;
  mapping(address => uint256) public pendingFeeByToken;

  struct Round {
    uint256 id;
    address inputToken;
    address outputToken;
    address pool;
    mapping(address => uint256) inputAmount;
    uint256 totalInputAmount;
    mapping(address => uint256) outputAmount;
    uint256 totalOutputAmount;
  }
  mapping(bytes32 => Round) public rounds;

  struct VaultCalc {
    address token;
    uint256 tokenBalance;
    uint256 input;
    uint256 correctInput;
    uint256 out;
    uint256 correctOut;
    uint256 poolAmountOut;
  }

  modifier onlyReporter(uint256 _reporterId, bytes calldata _rewardOpts) {
    uint256 gasStart = gasleft();
    powerPoke.authorizeReporter(_reporterId, msg.sender);
    _;
    _reward(_reporterId, gasStart, COMPENSATION_PLAN_1_ID, _rewardOpts);
  }

  modifier onlyNonReporter(uint256 _reporterId, bytes calldata _rewardOpts) {
    uint256 gasStart = gasleft();
    powerPoke.authorizeNonReporter(_reporterId, msg.sender);
    _;
    _reward(_reporterId, gasStart, COMPENSATION_PLAN_1_ID, _rewardOpts);
  }

  modifier onlyEOA() {
    require(tx.origin == msg.sender, "ONLY_EOA");
    _;
  }

  constructor(address _usdc, address _powerPoke) public {
    usdc = IERC20(_usdc);
    powerPoke = IPowerPoke(_powerPoke);
  }

  function initialize(uint256 _roundPeriod, address _feeReceiver) external initializer {
    __Ownable_init();
    feeReceiver = _feeReceiver;
    roundPeriod = _roundPeriod;
  }

  receive() external payable {
    oddEth = oddEth.add(msg.value);
  }

  function depositEth(address _pool) external payable onlyEOA {
    require(poolType[_pool] == PoolType.PIPT, "NOT_SUPPORTED_POOL");

    _deposit(_pool, ETH, _pool, msg.value);
  }

  function depositErc20(
    address _pool,
    address _inputToken,
    uint256 _amount
  ) external onlyEOA {
    require(poolType[_pool] != PoolType.NULL, "UNKNOWN_POOL");

    require(_inputToken == address(usdc), "NOT_SUPPORTED_TOKEN");

    _deposit(_pool, _inputToken, _pool, _amount);
  }

  function depositPoolToken(
    address _pool,
    address _outputToken,
    uint256 _amount
  ) external {
    PoolType pType = poolType[_pool];
    require(pType != PoolType.NULL, "UNKNOWN_POOL");

    require(_outputToken == address(usdc) || _outputToken == ETH, "NOT_SUPPORTED_TOKEN");

    _deposit(_pool, _pool, _outputToken, _amount);
  }

  function withdrawEth(address _pool, uint256 _amount) external onlyEOA {
    require(poolType[_pool] != PoolType.NULL, "UNKNOWN_POOL");

    _withdraw(_pool, ETH, _pool, _amount);
  }

  function withdrawErc20(
    address _pool,
    address _inputToken,
    uint256 _amount
  ) external onlyEOA {
    require(poolType[_pool] != PoolType.NULL, "UNKNOWN_POOL");

    _withdraw(_pool, _inputToken, _pool, _amount);
  }

  function withdrawPoolToken(
    address _pool,
    address _outputToken,
    uint256 _amount
  ) external onlyEOA {
    PoolType pType = poolType[_pool];
    require(pType != PoolType.NULL, "UNKNOWN_POOL");

    require(_outputToken == address(usdc) || _outputToken == ETH, "NOT_SUPPORTED_TOKEN");

    _withdraw(_pool, _pool, _outputToken, _amount);
  }

  function supplyAndRedeemPokeFromReporter(
    uint256 _reporterId,
    bytes32[] memory _roundKeys,
    bytes calldata _rewardOpts
  ) external onlyReporter(_reporterId, _rewardOpts) onlyEOA {
    _supplyAndRedeemPoke(_roundKeys);
  }

  function supplyAndRedeemPokeFromSlasher(
    uint256 _reporterId,
    bytes32[] memory _roundKeys,
    bytes calldata _rewardOpts
  ) external onlyNonReporter(_reporterId, _rewardOpts) onlyEOA {
    _supplyAndRedeemPoke(_roundKeys);
  }

  function supplyAndRedeemPoke(bytes32[] memory _roundKeys) external onlyEOA {
    _supplyAndRedeemPoke(_roundKeys);
  }

  function claimPokeFromReporter(
    uint256 _reporterId,
    bytes32 _roundKey,
    address[] memory _claimForList,
    bytes calldata _rewardOpts
  ) external onlyReporter(_reporterId, _rewardOpts) onlyEOA {
    _claimPoke(_roundKey, _claimForList);
  }

  function claimPokeFromSlasher(
    uint256 _reporterId,
    bytes32 _roundKey,
    address[] memory _claimForList,
    bytes calldata _rewardOpts
  ) external onlyNonReporter(_reporterId, _rewardOpts) onlyEOA {
    _claimPoke(_roundKey, _claimForList);
  }

  function claimPoke(bytes32 _roundKey, address[] memory _claimForList) external onlyEOA {
    _claimPoke(_roundKey, _claimForList);
  }

  function setRoundPeriod(uint256 _roundPeriod) external onlyOwner {
    roundPeriod = _roundPeriod;
  }

  function setPools(address[] memory _pools, PoolType[] memory _types) external onlyOwner {
    uint256 len = _pools.length;
    require(len == _types.length, "LENGTHS_NOT_EQUAL");
    for (uint256 i = 0; i < len; i++) {
      poolType[_pools[i]] = _types[i];
      _updatePool(_pools[i]);
    }
  }

  function setPoolsPiptSwap(address[] memory _pools, address[] memory _piptSwaps) external onlyOwner {
    uint256 len = _pools.length;
    require(len == _piptSwaps.length, "LENGTHS_NOT_EQUAL");
    for (uint256 i = 0; i < len; i++) {
      poolPiptSwap[_pools[i]] = _piptSwaps[i];
      usdc.approve(_piptSwaps[i], uint256(-1));
      IERC20(_pools[i]).approve(_piptSwaps[i], uint256(-1));
    }
  }

  function setVaultConfigs(
    address[] memory _tokens,
    address[] memory _depositors,
    uint256[] memory _depositorAmountLength,
    uint256[] memory _depositorIndexes,
    address[] memory _lpTokens,
    address[] memory _vaultRegistries
  ) external onlyOwner {
    uint256 len = _tokens.length;
    require(len == _depositors.length && len == _depositorIndexes.length, "LENGTHS_NOT_EQUAL");
    for (uint256 i = 0; i < len; i++) {
      vaultConfig[_tokens[i]] = VaultConfig(_depositorAmountLength[i], _depositorIndexes[i], _depositors[i], _lpTokens[i], _vaultRegistries[i]);

      usdc.approve(_depositors[i], uint256(-1));
      console.log("approve", _lpTokens[i]);
      console.log("_tokens[i]", _tokens[i]);
      IERC20(_lpTokens[i]).approve(_tokens[i], uint256(-1));
    }
  }

  function updatePools(address[] memory _pools) external onlyOwner {
    uint256 len = _pools.length;
    for (uint256 i = 0; i < len; i++) {
      _updatePool(_pools[i]);
    }
  }

  function setFee(address[] memory _tokens, uint256[] memory _fees) external onlyOwner {
    uint256 len = _tokens.length;
    require(len == _fees.length, "LENGTHS_NOT_EQUAL");
    for (uint256 i = 0; i < len; i++) {
      feeByToken[_tokens[i]] = _fees[i];
    }
  }

  function setFeeReceiver(address _feeReceiver) external onlyOwner {
    feeReceiver = _feeReceiver;
  }

  function claimFee(address[] memory _tokens) external onlyOwner {
    uint256 len = _tokens.length;
    for (uint256 i = 0; i < len; i++) {
      address token = _tokens[i];
      if (token == ETH) {
        payable(feeReceiver).transfer(pendingFeeByToken[token]);
      } else {
        IERC20(token).transfer(feeReceiver, pendingFeeByToken[token]);
      }
      pendingFeeByToken[token] = 0;
    }
  }

  function getCurrentRoundKey(
    address pool,
    address inputToken,
    address outputToken
  ) public view returns (bytes32) {
    return getRoundKey(roundCounter, pool, inputToken, outputToken);
  }

  function getRoundKey(
    uint256 id,
    address pool,
    address inputToken,
    address outputToken
  ) public view returns (bytes32) {
    return keccak256(abi.encodePacked(id, pool, inputToken, outputToken));
  }

  function getRoundUserInput(bytes32 roundKey, address user) public view returns (uint256) {
    return rounds[roundKey].inputAmount[user];
  }

  function getRoundUserOutput(bytes32 roundKey, address user) public view returns (uint256) {
    return rounds[roundKey].outputAmount[user];
  }

  function _deposit(
    address _pool,
    address _inputToken,
    address _outputToken,
    uint256 _amount
  ) internal {
    bytes32 roundKey = _updateRound(_pool, _inputToken, _outputToken);

    if (_inputToken != ETH) {
      IERC20(_inputToken).transferFrom(msg.sender, address(this), _amount);
    }

    Round storage round = rounds[roundKey];
    round.inputAmount[msg.sender] = round.inputAmount[msg.sender].add(_amount);
    round.totalInputAmount = round.totalInputAmount.add(_amount);
  }

  function _withdraw(
    address _pool,
    address _inputToken,
    address _outputToken,
    uint256 _amount
  ) internal {
    Round storage round = rounds[getCurrentRoundKey(_pool, _inputToken, _outputToken)];

    round.inputAmount[msg.sender] = round.inputAmount[msg.sender].sub(_amount);
    round.totalInputAmount = round.totalInputAmount.sub(_amount);

    if (_inputToken == ETH) {
      msg.sender.transfer(_amount);
    } else {
      IERC20(_inputToken).transfer(msg.sender, _amount);
    }
  }

  function _supplyAndRedeemPoke(bytes32[] memory _roundKeys) internal {
    _incrementRound();

    uint256 len = _roundKeys.length;
    require(len > 0, "NULL_LENGTH");

    for (uint256 i = 0; i < len; i++) {
      Round storage round = rounds[_roundKeys[i]];
      _checkRoundBeforeExecute(round);

      uint256 inputAmountWithFee = _takeAmountFee(round.inputToken, round.totalInputAmount);
      require(round.inputToken == round.pool || round.outputToken == round.pool, "UNKNOWN_ROUND_ACTION");

      console.log("round.totalInputAmount", round.totalInputAmount);
      console.log("inputAmountWithFee", inputAmountWithFee);
      if (round.inputToken == round.pool) {
        _redeemPool(round, inputAmountWithFee);
      } else {
        _supplyPool(round, inputAmountWithFee);
      }
    }
  }

  function _supplyPool(Round storage round, uint256 totalInputAmount) internal {
    PoolType pType = poolType[round.pool];
    if (pType == PoolType.PIPT) {
      Erc20PiptSwap piptSwap = Erc20PiptSwap(payable(poolPiptSwap[round.pool]));
      if (round.inputToken == ETH) {
        (round.totalOutputAmount, ) = piptSwap.swapEthToPipt{ value: totalInputAmount }(piptSwap.defaultSlippage());
      } else {
        round.totalOutputAmount = piptSwap.swapErc20ToPipt(
          round.inputToken,
          totalInputAmount,
          piptSwap.defaultSlippage()
        );
      }
    } else if (pType == PoolType.VAULT) {
      (uint256 poolAmountOut, uint256[] memory tokensInPipt) = _depositVaultAndGetTokensInPipt(round, totalInputAmount);

      PowerIndexPoolInterface(round.pool).joinPool(poolAmountOut, tokensInPipt);
      (, uint256 communityFee, , ) = PowerIndexPoolInterface(round.pool).getCommunityFee();
      round.totalOutputAmount = poolAmountOut.sub(poolAmountOut.mul(communityFee).div(1 ether)) - 1;
    }
  }

  function _depositVaultAndGetTokensInPipt(Round storage round, uint256 totalInputAmount) internal returns (uint256 poolAmountOut, uint256[] memory tokensInPipt) {
    uint256 len = poolTokens[round.pool].length;
    VaultCalc[] memory vc = new VaultCalc[](len);
    tokensInPipt = new uint256[](len);

    uint256 minPoolAmount;
    uint256 piptTotalSupply = PowerIndexPoolInterface(round.pool).totalSupply();
    {
      uint256 ratio = totalInputAmount.mul(1 ether).div(piptTotalSupply).add(100);
      for (uint256 i = 0; i < len; i++) {
        vc[i].token = poolTokens[round.pool][i];
        vc[i].tokenBalance = PowerIndexPoolInterface(round.pool).getBalance(vc[i].token);
        //          console.log("usdcSharesInPipt[i]", ratio.mul(tokensBalances[i]).div(1 ether));
        vc[i].input = ratio.mul(vc[i].tokenBalance).div(1 ether);
        //          console.log("tokensInPipt[i]", tokensInPipt[i]);
        vc[i].out = calcVaultOutByUsdc(vc[i].token, vc[i].input);
        vc[i].poolAmountOut = vc[i].out.mul(piptTotalSupply).div(vc[i].tokenBalance);
        if (minPoolAmount == 0 || vc[i].poolAmountOut < minPoolAmount) {
          minPoolAmount = vc[i].poolAmountOut;
        }
      }
    }

    uint256 restInput = 0;
    for (uint256 i = 0; i < len; i++) {
      if (vc[i].poolAmountOut > minPoolAmount) {
        uint256 ratio = minPoolAmount.mul(1 ether).div(vc[i].poolAmountOut);
        vc[i].correctInput = ratio.mul(vc[i].input).div(1 ether);
        restInput = restInput.add(vc[i].input.sub(vc[i].correctInput));
      } else {
        vc[i].correctInput = vc[i].input;
      }
    }

    uint256 totalCorrectInput = totalInputAmount.sub(restInput).sub(100);
    console.log("totalInputAmount", totalInputAmount);

    for (uint256 i = 0; i < len; i++) {
      uint256 share = vc[i].correctInput.mul(1 ether).div(totalCorrectInput);
      vc[i].correctInput = vc[i].correctInput.add(restInput.mul(share).div(1 ether));

      IVault(vc[i].token).deposit(_addYearnLpTokenLiquidity(round, vaultConfig[vc[i].token], vc[i].correctInput));
      tokensInPipt[i] = IVault(vc[i].token).balanceOf(address(this));

      uint256 poolOutByToken = tokensInPipt[i].sub(1e6).mul(piptTotalSupply).div(vc[i].tokenBalance);
      console.log("poolOutByToken", poolOutByToken);
      if (poolOutByToken < poolAmountOut || poolAmountOut == 0) {
        poolAmountOut = poolOutByToken;
      }
    }

    console.log("poolAmountOut", poolAmountOut);
  }

  function _addYearnLpTokenLiquidity(Round storage round, VaultConfig storage vc, uint256 _amount) internal returns (uint256) {
    if (vc.depositorLength == 2) {
      uint256[2] memory amounts;
      amounts[vc.depositorIndex] = _amount;
      IVaultDepositor2(vc.depositor).add_liquidity(amounts, 1);
    }

    if (vc.depositorLength == 3) {
      uint256[3] memory amounts;
      amounts[vc.depositorIndex] = _amount;
      IVaultDepositor3(vc.depositor).add_liquidity(amounts, 1);
    }

    if (vc.depositorLength == 4) {
      uint256[4] memory amounts;
      amounts[vc.depositorIndex] = _amount;
      IVaultDepositor4(vc.depositor).add_liquidity(amounts, 1);
    }
    return IERC20(vc.lpToken).balanceOf(address(this));
  }

  function _redeemPool(Round storage round, uint256 inputAmountWithFee) internal {
    PoolType pType = poolType[round.pool];
    if (pType == PoolType.PIPT) {
      Erc20PiptSwap piptSwap = Erc20PiptSwap(payable(poolPiptSwap[round.pool]));
      if (round.inputToken == ETH) {
        round.totalOutputAmount = piptSwap.swapPiptToEth(inputAmountWithFee);
      } else {
        round.totalOutputAmount = piptSwap.swapPiptToErc20(round.inputToken, inputAmountWithFee);
        console.log("round.totalOutputAmount", round.totalOutputAmount);
        console.log("pool.balanceOf(address(this))", IERC20(round.pool).balanceOf(address(this)));
      }
    }
  }

  function _claimPoke(bytes32 _roundKey, address[] memory _claimForList) internal {
    uint256 len = _claimForList.length;
    require(len > 0, "NULL_LENGTH");

    Round storage round = rounds[_roundKey];
    require(round.totalOutputAmount != 0, "TOTAL_OUTPUT_NULL");

    for (uint256 i = 0; i < len; i++) {
      address _claimFor = _claimForList[i];
      require(round.inputAmount[_claimFor] != 0, "INPUT_NULL");
      require(round.outputAmount[_claimFor] == 0, "OUTPUT_NOT_NULL");

      uint256 inputShare = round.inputAmount[_claimFor].mul(1 ether).div(round.totalInputAmount);
      uint256 outputAmount = round.totalOutputAmount.mul(inputShare).div(1 ether);
      console.log("outputAmount", outputAmount);
      console.log("pool.balanceOf(address(this))", IERC20(round.pool).balanceOf(address(this)));
      round.outputAmount[_claimFor] = outputAmount;
      IERC20(round.pool).transfer(_claimFor, outputAmount - 1);
    }
  }

  function _takeAmountFee(address _inputToken, uint256 _amount) internal returns (uint256 amountWithFee) {
    if (feeByToken[_inputToken] == 0) {
      return _amount;
    }
    amountWithFee = _amount.mul(feeByToken[_inputToken]).div(1 ether);
    if (amountWithFee != _amount) {
      pendingFeeByToken[_inputToken] = pendingFeeByToken[_inputToken].add(_amount.sub(amountWithFee));
    }
  }

  function _checkRoundBeforeExecute(Round storage round) internal {
    require(round.id != roundCounter, "CURRENT_ROUND");
    require(round.totalInputAmount != 0, "TOTAL_INPUT_NULL");
    require(round.totalOutputAmount == 0, "TOTAL_OUTPUT_NOT_NULL");
  }

  function _incrementRound() internal {
    if (lastRoundCreatedAt.add(roundPeriod) <= block.timestamp) {
      roundCounter = roundCounter.add(1);
      lastRoundCreatedAt = block.timestamp;
      emit NewRound(roundCounter, lastRoundCreatedAt);
    }
  }

  function _updateRound(
    address _pool,
    address _inputToken,
    address _outputToken
  ) internal returns (bytes32 roundKey) {
    _incrementRound();

    roundKey = getCurrentRoundKey(_pool, _inputToken, _outputToken);

    if (rounds[roundKey].pool == address(0)) {
      rounds[roundKey].id = roundCounter;
      rounds[roundKey].pool = _pool;
      rounds[roundKey].inputToken = _inputToken;
      rounds[roundKey].outputToken = _outputToken;
      emit InitRoundKey(roundCounter, roundKey, _pool, _inputToken, _outputToken);
    }

    return roundKey;
  }

  function _updatePool(address _pool) internal {
    poolTokens[_pool] = PowerIndexPoolInterface(_pool).getCurrentTokens();
    if (poolType[_pool] == PoolType.VAULT) {
      uint256 len = poolTokens[_pool].length;
      for (uint256 i = 0; i < len; i++) {
        IERC20(poolTokens[_pool][i]).approve(_pool, uint256(-1));
      }
    }
  }

  function _reward(
    uint256 _reporterId,
    uint256 _gasStart,
    uint256 _compensationPlan,
    bytes calldata _rewardOpts
  ) internal {
    powerPoke.reward(_reporterId, _gasStart.sub(gasleft()), _compensationPlan, _rewardOpts);
  }

  function _getMinMaxReportInterval() internal view returns (uint256 min, uint256 max) {
    return powerPoke.getMinMaxReportIntervals(address(this));
  }

  function calcVaultOutByUsdc(address _token, uint256 _usdcIn) public view returns (uint256 amountOut) {
    VaultConfig storage vc = vaultConfig[_token];
    uint256 lpByUsdcPrice = IVaultRegistry(vc.vaultRegistry).get_virtual_price_from_lp_token(vc.lpToken);
    uint256 vaultByLpPrice = IVault(_token).getPricePerFullShare();
    return _usdcIn.mul(1e30).div(vaultByLpPrice.mul(lpByUsdcPrice).div(1 ether));
  }
}