require('@nomiclabs/hardhat-truffle5');

const pIteration = require('p-iteration');
const fs = require('fs');

task('deploy-testnet-pool', 'Deploy Testnet Pool').setAction(async (__, {ethers, network}) => {
  const {impersonateAccount, callContract} = require('../test/helpers');

  const PowerIndexPoolFactory = await artifacts.require('PowerIndexPoolFactory');
  const PowerIndexPoolActions = await artifacts.require('PowerIndexPoolActions');
  const PowerIndexPool = await artifacts.require('PowerIndexPool');
  const MockERC20 = await artifacts.require('MockERC20');
  const UniswapV2Factory = artifacts.require('MockUniswapV2Factory');
  const UniswapV2Router02 = artifacts.require('UniswapV2Router02');
  const UniswapV2Pair = artifacts.require('UniswapV2Pair');
  const ProxyFactory = artifacts.require('ProxyFactory');

  const { web3 } = PowerIndexPoolFactory;
  const { toWei } = web3.utils;

  const [deployer] = await web3.eth.getAccounts();
  console.log('deployer', deployer);
  const sendOptions = { from: deployer };

  const weth = await MockERC20.new('WETH', 'WETH', '18', ether('1000000000'));
  console.log('weth.address', weth.address);

  const impl = await PowerIndexPool.new();

  const proxyFactory = await ProxyFactory.new(sendOptions);
  const bFactory = await PowerIndexPoolFactory.new(proxyFactory.address, impl.address, deployer, sendOptions);
  const bActions = await PowerIndexPoolActions.new(sendOptions);

  const uniswapFactory = await UniswapV2Factory.new(deployer, sendOptions);
  console.log('uniswapFactory.address', uniswapFactory.address);
  const uniswapRouter = await UniswapV2Router02.new(uniswapFactory.address, weth.address, sendOptions);
  console.log('uniswapRouter.address', uniswapRouter.address);

  const poolsData = JSON.parse(fs.readFileSync('data/poolsData.json', { encoding: 'utf8' }));

  const bPoolBalances = [];
  const tokens = [];
  const pairByTokenAddress = {};
  for (let i = 0; i < poolsData.length; i++) {
    const token = await MockERC20.new(poolsData[i].tokenSymbol, poolsData[i].tokenSymbol, poolsData[i].tokenDecimals, ether('10000000000'));

    pairByTokenAddress[token.address] = await makeUniswapPair(
      token,
      poolsData[i].uniswapPair.tokenReserve,
      poolsData[i].uniswapPair.ethReserve,
      poolsData[i].uniswapPair.isReverse,
    );
    console.log(poolsData[i].tokenSymbol, 'pair', pairByTokenAddress[token.address].address);
    tokens.push(token);
    bPoolBalances.push(poolsData[i].balancerBalance);
  }

  const balancerTokens = tokens.filter((t, i) => poolsData[i].balancerBalance !== '0');

  const pool = await makePowerIndexPool(balancerTokens, bPoolBalances.filter(b => b !== '0'));
  console.log('pool.address', pool.address);

  async function makePowerIndexPool(_tokens, _balances) {
    const fromTimestamp = await getTimestamp(100);
    const targetTimestamp = await getTimestamp(100 + 60 * 5);
    for (let i = 0; i < _tokens.length; i++) {
      await _tokens[i].approve(bActions.address, '0x' + 'f'.repeat(64));
      console.log('approve', _tokens[i].address);
    }

    const weightPart = 50 / _tokens.length;
    const minWeightPerSecond = ether('0.00000001');
    const maxWeightPerSecond = ether('0.1');

    const swapFee = ether('0.0001');
    const communitySwapFee = ether('0.001');
    const communityJoinFee = ether('0.001');
    const communityExitFee = ether('0.001');

    const res = await bActions.create(
      bFactory.address,
      'Test Pool',
      'TP',
      {
        minWeightPerSecond,
        maxWeightPerSecond,
        swapFee,
        communitySwapFee,
        communityJoinFee,
        communityExitFee,
        communityFeeReceiver: deployer,
        finalize: true,
      },
      _tokens.map((t, i) => ({
        token: t.address,
        balance: _balances[i],
        targetDenorm: ether(weightPart),
        fromTimestamp: fromTimestamp.toString(),
        targetTimestamp: targetTimestamp.toString()
      })),
    );

    const logNewPool = PowerIndexPoolFactory.decodeLogs(res.receipt.rawLogs).filter(l => l.event === 'LOG_NEW_POOL')[0];
    return PowerIndexPool.at(logNewPool.args.pool);
  }

  async function getTimestamp(shift = 0) {
    const currentTimestamp = (await web3.eth.getBlock(await web3.eth.getBlockNumber())).timestamp;
    return currentTimestamp + shift;
  }

  async function makeUniswapPair (_token, _tokenBalance, _wethBalance, isReverse) {
    const token0 = isReverse ? weth.address : _token.address;
    const token1 = isReverse ? _token.address : weth.address;
    const res = await uniswapFactory.createPairMock(token0, token1);
    const pair = await UniswapV2Pair.at(res.logs[0].args.pair);
    await _token.transfer(pair.address, _tokenBalance);
    await weth.transfer(pair.address, _wethBalance);
    await pair.mint(deployer);
    return pair;
  }

  function ether(amount) {
    return toWei(amount.toString(), 'ether');
  }
});
