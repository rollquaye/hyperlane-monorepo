import { ethers } from 'ethers';
import { ChainConfig } from './config/chain';
import { Contracts } from './contracts';
import path from 'path';

export enum DeployEnvironment {
  dev = 'dev',
  testnet = 'testnet',
  mainnet = 'mainnet',
  testnetLegacy = 'testnet-legacy',
  mainnetLegacy = 'mainnet-legacy',
  test = 'test',
}

type XAppConnectionName = 'XAppConnectionManager';
type ValidatorManagerName = 'ValidatorManager';
type UBCName = 'UpgradeBeaconController';
type OutboxName =
  | 'Outbox UpgradeBeacon'
  | 'Outbox Proxy'
  | 'Outbox Implementation';
type InboxName = 'Inbox UpgradeBeacon' | 'Inbox Proxy' | 'Inbox Implementation';
type GovernanceName =
  | 'Governance UpgradeBeacon'
  | 'Governance Proxy'
  | 'Governance Implementation';
type EthHelperName = 'ETH Helper';
type BridgeTokenName =
  | 'BridgeToken UpgradeBeacon'
  | 'BridgeToken Proxy'
  | 'BridgeToken Implementation';
type BridgeRouterName =
  | 'BridgeRouter UpgradeBeacon'
  | 'BridgeRouter Proxy'
  | 'BridgeRouter Implementation';

export type ContractVerificationName =
  | XAppConnectionName
  | ValidatorManagerName
  | UBCName
  | OutboxName
  | InboxName
  | GovernanceName
  | EthHelperName
  | BridgeTokenName
  | BridgeRouterName;

export type ContractVerificationInput = {
  name: ContractVerificationName;
  address: string;
  constructorArguments: any[];
  isProxy?: boolean;
};

export abstract class Deploy<T extends Contracts> {
  readonly chain: ChainConfig;
  readonly test: boolean;
  readonly environment: DeployEnvironment;
  contracts: T;
  verificationInput: ContractVerificationInput[];

  abstract get ubcAddress(): string | undefined;

  constructor(
    chain: ChainConfig,
    contracts: T,
    environment: DeployEnvironment,
    test: boolean = false,
  ) {
    this.chain = chain;
    this.verificationInput = [];
    this.test = test;
    this.contracts = contracts;
    this.environment = environment;
  }

  get signer(): ethers.Signer {
    return this.chain.signer;
  }

  async ready(): Promise<ethers.providers.Network> {
    return await this.provider.ready;
  }

  get provider(): ethers.providers.JsonRpcProvider {
    return this.chain.provider;
  }

  get supports1559(): boolean {
    let notSupported = ['kovan', 'alfajores', 'baklava', 'celo', 'polygon'];
    return notSupported.indexOf(this.chain.name) === -1;
  }

  get configPath(): string {
    return path.join('./config/environments', this.environment);
  }

  // this is currently a kludge to account for ethers issues
  get overrides(): ethers.Overrides {
    let overrides: ethers.Overrides;

    if (this.supports1559) {
      overrides = {
        maxFeePerGas: this.chain.maxFeePerGas,
        maxPriorityFeePerGas: this.chain.maxPriorityFeePerGas,
        gasLimit: this.chain.gasLimit,
      };
    } else {
      overrides = {
        type: 0,
        gasPrice: this.chain.gasPrice,
        gasLimit: this.chain.gasLimit,
      };
    }

    return overrides;
  }
}