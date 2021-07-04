import {HardhatUserConfig} from 'hardhat/config';
import '@nomiclabs/hardhat-ethers';
import '@nomiclabs/hardhat-waffle';
import '@nomiclabs/hardhat-etherscan';

import './tasks/deploy';

require('dotenv').config();

const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;

export default {
  defaultNetwork: 'hardhat',
  networks: {
    hardhat: {
      forking: {
        url: process.env.ALCHEMY_MAINNET
      }
    },
    mainnet: {
      url: process.env.ALCHEMY_MAINNET,
      accounts: [`0x${DEPLOYER_PRIVATE_KEY}`]
    }
  },
  solidity: {
    compilers: [
      {version: '0.8.0'},
      {version: '0.7.4'},
      {version: '0.6.12'},
      {version: '0.5.17'}
    ]
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_KEY
  }
} as HardhatUserConfig;
