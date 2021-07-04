import {ethers, network} from 'hardhat';
import {Contract} from '@ethersproject/contracts';

const WANT_HOLDER = 'WANT_TOKEN_HOLDER_ADDRESS';
const WANT = 'WANT_TOKEN_ADDRESS';
const GOVERNANCE = 'GOV ADDRESS';

describe('Iron', function () {
  let vault: Contract;
  let controller: Contract;
  let strategy: Contract;

  before(async function () {
    this.enableTimeouts(false);

    await network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [WANT_HOLDER]
    });

    const Strategy = await ethers.getContractFactory('StrategyTemplate');
    const Vault = await ethers.getContractFactory('Vault');
    const Controller = await ethers.getContractFactory('Controller');

    controller = await Controller.deploy(GOVERNANCE);
    vault = await Vault.deploy(WANT, controller.address, GOVERNANCE);
    strategy = await Strategy.deploy(controller.address);

    const tx0 = await controller.setVault(WANT, vault.address);
    await tx0.wait();

    const tx1 = await controller.approveStrategy(WANT, strategy.address);
    await tx1.wait();

    const tx2 = await controller.setStrategy(WANT, strategy.address);
    await tx2.wait();
  });

  it('deposit', async function () {
    this.enableTimeouts(false);
  });
});
