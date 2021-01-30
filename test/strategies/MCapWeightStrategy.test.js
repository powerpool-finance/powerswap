const fs = require('fs');

const { time } = require('@openzeppelin/test-helpers');
const assert = require('chai').assert;
const PowerIndexPoolFactory = artifacts.require('PowerIndexPoolFactory');
const PowerIndexPoolActions = artifacts.require('PowerIndexPoolActions');
const PowerIndexPool = artifacts.require('PowerIndexPool');
const MockERC20 = artifacts.require('MockERC20');
const UniswapV2Factory = artifacts.require('MockUniswapV2Factory');
const UniswapV2Pair = artifacts.require('UniswapV2Pair');
const UniswapV2Router02 = artifacts.require('UniswapV2Router02');
const WETH = artifacts.require('MockWETH');
const PoolRestrictions = artifacts.require('PoolRestrictions');
const PowerIndexPoolController = artifacts.require('PowerIndexPoolController');
const ProxyFactory = artifacts.require('ProxyFactory');
const MCapWeightStrategy = artifacts.require('MCapWeightStrategy');
const MockOracle = artifacts.require('MockOracle');
const ethers = require('ethers');
const pIteration = require('p-iteration');

WETH.numberFormat = 'String';
MockERC20.numberFormat = 'String';
UniswapV2Pair.numberFormat = 'String';
UniswapV2Router02.numberFormat = 'String';
MCapWeightStrategy.numberFormat = 'String';
PowerIndexPool.numberFormat = 'String';

const { web3 } = PowerIndexPoolFactory;
const { toBN } = web3.utils;

function ether(val) {
  return web3.utils.toWei(val.toString(), 'ether').toString();
}

async function getTimestamp(shift = 0) {
  const currentTimestamp = (await web3.eth.getBlock(await web3.eth.getBlockNumber())).timestamp;
  return currentTimestamp + shift;
}

function divScalarBN(bn1, bn2) {
  return toBN(bn1.toString(10))
    .mul(toBN(ether('1').toString(10)))
    .div(toBN(bn2.toString(10)))
    .toString(10);
}
function mulScalarBN(bn1, bn2) {
  return toBN(bn1.toString(10))
    .mul(toBN(bn2.toString(10)))
    .div(toBN(ether('1').toString(10)))
    .toString(10);
}

function assertEqualWithAccuracy(bn1, bn2, accuracyPercentWei = '100000000') {
  bn1 = toBN(bn1.toString(10));
  bn2 = toBN(bn2.toString(10));
  const bn1GreaterThenBn2 = bn1.gt(bn2);
  let diff = bn1GreaterThenBn2 ? bn1.sub(bn2) : bn2.sub(bn1);
  let diffPercent = divScalarBN(diff, bn1);
  const lowerThenAccurancy = toBN(diffPercent).lte(toBN(accuracyPercentWei));
  assert.equal(lowerThenAccurancy, true, 'diffPercent is ' + web3.utils.fromWei(diffPercent, 'ether'));
}

describe('MCapWeightStrategy', () => {
  const zeroAddress = '0x0000000000000000000000000000000000000000';
  const swapFee = ether('0.0001');
  const communitySwapFee = ether('0.001');
  const communityJoinFee = ether('0.001');
  const communityExitFee = ether('0.001');

  const poolsData = JSON.parse(fs.readFileSync('data/poolsData.json', { encoding: 'utf8' }));

  let minter, feeManager, permanentVotingPower;
  before(async function () {
    [minter, feeManager, permanentVotingPower] = await web3.eth.getAccounts();
  });

  beforeEach(async () => {
    this.weth = await WETH.new();
    this.weth.deposit({ value: ether('50000000') });

    const proxyFactory = await ProxyFactory.new();
    const impl = await PowerIndexPool.new();
    this.bFactory = await PowerIndexPoolFactory.new(
      proxyFactory.address,
      impl.address,
      zeroAddress,
      { from: minter }
    );
    this.bActions = await PowerIndexPoolActions.new({ from: minter });
    this.uniswapFactory = await UniswapV2Factory.new(feeManager, { from: minter });
    this.uniswapRouter = await UniswapV2Router02.new(this.uniswapFactory.address, this.weth.address, { from: minter });

    this.poolRestrictions = await PoolRestrictions.new();

    this.makePowerIndexPool = async (_tokens, _balances) => {
      const fromTimestamp = await getTimestamp(100);
      const targetTimestamp = await getTimestamp(100 + 60 * 60 * 24 * 5);
      for (let i = 0; i < _tokens.length; i++) {
        await _tokens[i].approve(this.bActions.address, '0x' + 'f'.repeat(64));
      }

      const weightPart = 50 / _tokens.length;
      const minWeightPerSecond = ether('0');
      const maxWeightPerSecond = ether('0.1');

      const res = await this.bActions.create(
        this.bFactory.address,
        'Test Pool',
        'TP',
        {
          minWeightPerSecond,
          maxWeightPerSecond,
          swapFee,
          communitySwapFee,
          communityJoinFee,
          communityExitFee,
          communityFeeReceiver: permanentVotingPower,
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
      const pool = await PowerIndexPool.at(logNewPool.args.pool);
      await pool.setRestrictions(this.poolRestrictions.address, { from: minter });

      return pool;
    };

    this.checkWeights = async (pool, balancerTokens, weights) => {
      for (let i = 0; i < weights.length; i++) {
        const dw = await pool.getDynamicWeightSettings(balancerTokens[i].address);
        console.log(web3.utils.fromWei(dw.targetDenorm, 'ether'));
        assertEqualWithAccuracy(dw.targetDenorm, weights[i]);
      }
    };
  });

  describe('Swaps with Uniswap mainnet values', () => {
    let tokens, balancerTokens, bPoolBalances, pool, poolController, weightStrategy, oracle;

    const tokenBySymbol = {};
    const pokePeriod = 60 * 60 * 24;

    beforeEach(async () => {
      oracle = await MockOracle.new();
      weightStrategy = await MCapWeightStrategy.new(oracle.address, pokePeriod);
      tokens = [];
      balancerTokens = [];
      bPoolBalances = [];

      for (let i = 0; i < poolsData.length; i++) {
        const token = await MockERC20.new(poolsData[i].tokenSymbol, poolsData[i].tokenSymbol, poolsData[i].tokenDecimals, poolsData[i].totalSupply);

        console.log('token.address', token.address, 'poolsData.oraclePrice', poolsData[i].oraclePrice);
        await oracle.setPrice(token.address, poolsData[i].oraclePrice);
        const excludeAddresses = await pIteration.map(poolsData[i].excludeBalances, (bal) => {
          const {address} = ethers.Wallet.createRandom();
          token.transfer(address, bal);
          return address;
        });
        await weightStrategy.setExcludeTokenBalances(token.address, excludeAddresses);

        tokens.push(token);
        bPoolBalances.push(poolsData[i].balancerBalance);

        tokenBySymbol[poolsData[i].tokenSymbol] = {
          token,
        };
      }

      balancerTokens =  tokens.filter((t, i) => poolsData[i].balancerBalance !== '0');

      pool = await this.makePowerIndexPool(balancerTokens, bPoolBalances.filter(b => b !== '0'));
      poolController = await PowerIndexPoolController.new(pool.address, zeroAddress, zeroAddress, zeroAddress);
      await pool.setController(poolController.address);
      await weightStrategy.addPool(pool.address, poolController.address);
      await poolController.setWeightsStrategy(weightStrategy.address);

      await time.increase(12 * 60 * 60);
    });

    it('swapEthToPipt should work properly', async () => {
      await this.checkWeights(pool, balancerTokens, [
        ether(6.25),
        ether(6.25),
        ether(6.25),
        ether(6.25),
        ether(6.25),
        ether(6.25),
        ether(6.25),
        ether(6.25),
      ]);

      const newWeights = [
        ether(9.2213040233747008),
        ether(1.7634472718171779),
        ether(4.7045983418699305),
        ether(0.0805348660510209),
        ether(3.7464541219620122),
        ether(0.13546105725390025),
        ether(2.76111233776649315),
        ether(27.5870879799047642),
      ];

      let res = await weightStrategy.poke([pool.address]);
      assert.equal(res.logs.length, 9);

      await this.checkWeights(pool, balancerTokens, newWeights);

      await time.increase(pokePeriod);
      res = await weightStrategy.poke([pool.address]);
      assert.equal(res.logs.length, 9);

      await this.checkWeights(pool, balancerTokens, newWeights);

      let newTokenPrice = mulScalarBN(await oracle.assetPrices(balancerTokens[0].address), ether(1.1));
      await oracle.setPrice(balancerTokens[0].address, newTokenPrice);

      res = await weightStrategy.poke([pool.address]);
      assert.equal(res.logs.length, 0);
      await time.increase(pokePeriod);

      res = await weightStrategy.poke([pool.address]);
      assert.equal(res.logs.length, 9);

      await this.checkWeights(pool, balancerTokens, [
        ether(9.95975064826289985),
        ether(1.7315136443468895),
        ether(4.6194044757149202),
        ether(0.0790764893521855),
        ether(3.67861094219856055),
        ether(0.13300804206699305),
        ether(2.71111235522831755),
        ether(27.08752340282923305),
      ]);

      newTokenPrice = mulScalarBN(await oracle.assetPrices(balancerTokens[0].address), ether(2));
      await oracle.setPrice(balancerTokens[0].address, newTokenPrice);

      await time.increase(pokePeriod);
      res = await weightStrategy.poke([pool.address]);
      assert.equal(res.logs.length, 9);

      await this.checkWeights(pool, balancerTokens, [
        ether(16.61072726384235695),
        ether(1.4438966353482103),
        ether(3.85208779704018785),
        ether(0.0659413093760726),
        ether(3.067566911492096),
        ether(0.1109144389602681),
        ether(2.26077687608500875),
        ether(22.58808876785579865),
      ]);

      newTokenPrice = mulScalarBN(await oracle.assetPrices(balancerTokens[7].address), ether(0.5));
      await oracle.setPrice(balancerTokens[7].address, newTokenPrice);

      await time.increase(pokePeriod);
      res = await weightStrategy.poke([pool.address]);
      assert.equal(res.logs.length, 9);

      await this.checkWeights(pool, balancerTokens, [
        ether(21.4575857893881677),
        ether(1.8652124878020744),
        ether(4.9760918387462095),
        ether(0.085182381272472),
        ether(3.9626549230815687),
        ether(0.1432782593723283),
        ether(2.92045092299213655),
        ether(14.58954339734504205),
      ]);
    });
  });
});
