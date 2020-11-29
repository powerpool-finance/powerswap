const { time, ether: rEther } = require('@openzeppelin/test-helpers');
const { artifactFromBytecode } = require('./helpers/index');
const assert = require('chai').assert;
const MockERC20 = artifacts.require('MockERC20');
const AavePowerIndexRouter = artifacts.require('AavePowerIndexRouter');
const WrappedPiErc20 = artifacts.require('WrappedPiErc20');
const PoolRestrictions = artifacts.require('PoolRestrictions');
const { web3 } = MockERC20;

const StakedAave = artifactFromBytecode('aave/StakedAave')
const AaveProtoGovernance = artifactFromBytecode('aave/AaveProtoGovernance')
const AssetVotingWeightProvider = artifactFromBytecode('aave/AssetVotingWeightProvider')
const GovernanceParamsProvider = artifactFromBytecode('aave/GovernanceParamsProvider')
const AaveVoteStrategyToken = artifactFromBytecode('aave/AaveVoteStrategyToken')

MockERC20.numberFormat = 'String';
AavePowerIndexRouter.numberFormat = 'String';
WrappedPiErc20.numberFormat = 'String';

function ether(value) {
  return rEther(value.toString()).toString(10);
}

describe('AaveRouter Tests', () => {
  let minter, bob, alice, yearnOwner, rewardsVault, emissionManager, lendToken;

  before(async function () {
    [minter, bob, alice, yearnOwner, rewardsVault, emissionManager, lendToken] = await web3.eth.getAccounts();
  });

  it.only('should allow depositing Aave and staking it in a StakedAave contract', async () => {
    // 0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9
    const aave = await MockERC20.new('Aave Token', 'AAVE', '18', ether('1000000'));

    // Setting up Aave Governance and Staking
    // 0x4da27a545c0c5B758a6BA100e3a049001de870f5
    const stakedAave = await StakedAave.new(
      // 0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9
      aave.address,
      // 0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9
      aave.address,
      864000, 172800, rewardsVault, emissionManager, 12960000
    );

    // 0xa5e83c1a6e56f27f7764e5c5d99a9b8786e3a391
    const votingStrategy = await AaveVoteStrategyToken.new(aave.address, stakedAave.address);

    // 0x72bbcfc20d355fc3e8ac4ce8fcaf63874f746631
    const aavePropositionPower = await MockERC20.new('Aave Proposition Power', 'APP', '18', ether('1000000'));

    // 0x5ac493b8c2cef1f02f117b9ba2797e7da95574aa
    const weightProvider = await AssetVotingWeightProvider.new(
      // [0xa5e83c1a6e56f27f7764e5c5d99a9b8786e3a391]
      [votingStrategy.address],
      [100]
    );

    // 0xf7ff0aee0c2d6fbdea3a85742443e284b62fd0b2
    const paramsProvider = await GovernanceParamsProvider.new(
      2,
      // 0x72bbcfc20d355fc3e8ac4ce8fcaf63874f746631
      aavePropositionPower.address,
      // 0x5ac493b8c2cef1f02f117b9ba2797e7da95574aa
      weightProvider.address
    );

    // 0x8a2efd9a790199f4c94c6effe210fce0b4724f52
    const governance = await AaveProtoGovernance.new(
      // 0xf7ff0aee0c2d6fbdea3a85742443e284b62fd0b2
      paramsProvider.address
    );

    const poolRestrictions = await PoolRestrictions.new();
    const router = await AavePowerIndexRouter.new(poolRestrictions.address);

    const aaveWrapper = await WrappedPiErc20.new(aave.address, router.address, 'wrapped.aave', 'WAAVE');

    await router.setVotingAndStackingForWrappedToken(aaveWrapper.address, governance.address, stakedAave.address);
    await router.setReserveRatioForWrappedToken(aaveWrapper.address, ether('0.2'));

    assert.equal(await router.owner(), minter);

    await aave.transfer(alice, ether('10000'));
    await aave.approve(aaveWrapper.address, ether('10000'), { from: alice });
    await aaveWrapper.deposit(ether('10000'), { from: alice });

    assert.equal(await aaveWrapper.totalSupply(), ether('10000'));
    assert.equal(await aaveWrapper.balanceOf(alice), ether('10000'));

    return;
    // The router has partially staked the deposit with regard to the reserve ration value (20/80)
    assert.equal(await aave.balanceOf(aaveWrapper.address), ether(2000));
    assert.equal(await aave.balanceOf(yearnGovernance.address), ether(8000));

    // The votes are allocated on the yfiWrapper contract
    assert.equal(await stakedAave.balanceOf(aaveWrapper.address), ether(8000));

    const proposalString = 'Lets do it';

    await poolRestrictions.setVotingAllowedForSenders(stakedAave.address, [alice], [true]);

    await router.executeRegister(aaveWrapper.address, { from: alice });
    await router.executePropose(aaveWrapper.address, bob, proposalString, { from: alice });
    await router.executeVoteFor(aaveWrapper.address, 0, { from: alice });

    await time.advanceBlockTo((await time.latestBlock()).toNumber() + 10);

    await yearnGovernance.tallyVotes(0);

    const proposal = await yearnGovernance.proposals(0);
    assert.equal(proposal.open, false);
    assert.equal(proposal.totalForVotes, ether(8000));
    assert.equal(proposal.totalAgainstVotes, ether(0));
    assert.equal(proposal.hash, proposalString);
  });
});
