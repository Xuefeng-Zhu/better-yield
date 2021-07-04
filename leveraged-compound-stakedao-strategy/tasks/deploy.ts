import {task} from 'hardhat/config';

const USDC = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174';

task('deploy-strategy', 'Deploy whole strategy setup')
  .addFlag('verify', 'verify contracts on etherscan')
  .setAction(async (args, {ethers, run, network}) => {
    console.log('Network:', network.name);
    console.log('Task Args:', args);

    await run('compile');

    const signer = (await ethers.getSigners())[0];

    const Strategy = await ethers.getContractFactory('StrategyTemplate');
    const YVault = await ethers.getContractFactory('Vault');
    const Controller = await ethers.getContractFactory('Controller');

    const controller = await Controller.deploy(signer.address);
    const vault = await YVault.deploy(USDC, controller.address, signer.address);
    const strategy = await Strategy.deploy(controller.address);

    const tx0 = await controller.setVault(USDC, vault.address);
    await tx0.wait();

    const tx1 = await controller.approveStrategy(USDC, strategy.address);
    await tx1.wait();

    const tx2 = await controller.setStrategy(USDC, strategy.address);
    await tx2.wait();

    await strategy.deployTransaction.wait(5);
    await controller.deployTransaction.wait(5);
    await vault.deployTransaction.wait(5);

    await run('verify:verify', {
      address: strategy.address,
      contract: 'contracts/StrategyTemplate.sol:StrategyTemplate',
      constructorArguments: [controller.address]
    });

    await run('verify:verify', {
      address: vault.address,
      contract: 'contracts/Vault.sol:Vault',
      constructorArguments: [USDC, controller.address, signer.address]
    });

    await run('verify:verify', {
      address: controller.address,
      contract: 'contracts/Controller.sol:Controller',
      constructorArguments: [signer.address]
    });
  });
