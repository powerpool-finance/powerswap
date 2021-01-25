require('@nomiclabs/hardhat-truffle5');

const assert = require('assert');

task('test-vested-lp-mining-calc', 'Test VestedLpMining Calculation').setAction(async (__, { ethers }) => {
  const MockERC20 = await artifacts.require('MockERC20');
  const MockVestedLPMining = await artifacts.require('MockVestedLPMining');
  const PowerIndexPool = await artifacts.require('PowerIndexPool');
  const UniswapV2Router02 = await artifacts.require('UniswapV2Router02');
  const Erc20PiptSwap = await artifacts.require('Erc20PiptSwap');
  const {impersonateAccount, callContract, ether, advanceBlocks, forkContractUpgrade} = require('../test/helpers');
  const {web3} = MockERC20;

  const [operator] = await web3.eth.getAccounts();
  const sendOptions = {from: operator};

  const OWNER = '0xB258302C3f209491d604165549079680708581Cc';
  const cvp = await MockERC20.at('0x38e4adb44ef08f22f5b5b76a8f0c2d0dcbe7dca1');
  const pool = await PowerIndexPool.at('0xfa2562da1bba7b954f26c74725df51fb62646313');
  const erc20PiptSwap = await Erc20PiptSwap.at('0x4a323f52685b160576257c968f679bbec5076f36');
  const mining = await MockVestedLPMining.at('0xF09232320eBEAC33fae61b24bB8D7CA192E58507');
  const uniswapRouter = await UniswapV2Router02.at('0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D');
  const pid = '10';

  await forkContractUpgrade(ethers, OWNER, '0x4bb5A5b7E10C98884960bbDB9540cD1BaBdEac68', mining.address, (await MockVestedLPMining.new()).address);

  console.log('ether(web3.utils.toWei(\'0.9483667018\', \'szabo\'))', ether(web3.utils.toWei('0.9483667018', 'szabo')));
  const poolInfo = await mining.pools(pid);
  await mining.set(
    pid,
    poolInfo.allocPoint,
    '1',
    false,
    ether(web3.utils.toWei('0.9483667018', 'szabo')),
    ether(web3.utils.toWei('0.9483667018', 'szabo')),
    await mining.lpBoostRatioByToken(poolInfo.lpToken),
    await mining.lpBoostMaxRatioByToken(poolInfo.lpToken),
    {from: OWNER}
  );

  const cvpToDeposit = ether('50');
  const lpToDeposit = ether('100');

  console.log(
    'min cvp to boost',
    weiToEther(await mining.cvpBalanceToBoost(lpToDeposit, pool.address, true)),
    'max cvp to boost',
    weiToEther(await mining.cvpBalanceToBoost(lpToDeposit, pool.address, false))
  )
  const uniswapPath = ['0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2', cvp.address];

  const ethAmountInForCvp = await uniswapRouter.getAmountsIn(cvpToDeposit, uniswapPath).then(res => res[0]);
  await uniswapRouter.swapExactETHForTokens(cvpToDeposit, uniswapPath, operator, Math.round(new Date().getTime() / 1000) + 1000, {
    value: ethAmountInForCvp,
    from: operator
  });

  await erc20PiptSwap.swapEthToPiptByPoolOut(addBN(lpToDeposit, ether('10')), {value: ether('1'), from: operator});

  await pool.approve(mining.address, lpToDeposit, sendOptions);
  await cvp.approve(mining.address, cvpToDeposit, sendOptions);

  await mining.deposit(pid, lpToDeposit, cvpToDeposit, sendOptions);

  const poolBoost = await mining.poolBoostByLp(pid);

  console.log('block number before', await web3.eth.getBlockNumber());

  await advanceBlocks(6499);

  console.log('__computeReward lp', await mining.__computeReward(poolBoost.lastUpdateBlock, '0', pool.address, poolBoost.lpBoostRate))
  console.log('__computeReward cvp', await mining.__computeReward(poolBoost.lastUpdateBlock, '0', cvp.address, poolBoost.cvpBoostRate))
  console.log('poolBoost', poolBoost);
  console.log('usersPoolBoost', weiToEther(await mining.usersPoolBoost(pid, operator).then(pb => pb.balance)));

  console.log('block number after', await web3.eth.getBlockNumber());

  console.log('cvp balance before claim', weiToEther(await cvp.balanceOf(operator)));
  console.log('pendingCvp', weiToEther(await mining.pendingCvp(pid, operator)));

  await mining.deposit(pid, '0', '0');

  console.log('poolBoost', await mining.poolBoostByLp(pid));

  console.log('cvp balance after claim', weiToEther(await cvp.balanceOf(operator)));

  function weiToEther(wei) {
    return web3.utils.fromWei(wei.toString(), 'ether');
  }
  function addBN(bn1, bn2) {
    return web3.utils.toBN(bn1.toString()).add(web3.utils.toBN(bn2.toString()));
  }
});
