import { createPublicClient, defineChain, fallback, http, isAddress, type Abi, type Address } from 'viem';
import { abiHash } from './canonical';

export type Deployment = {
  version: number; launchId: string; chainId: number; sourceCommit: string; attestationHash: string;
  contracts: { name: string; address: Address; abiHash: string; abiPath: string }[];
  assets: { path: string; sha256: string }[];
  network: {
    chainId: number; name: string; testnet: boolean; rpcUrls: string[]; explorer: string;
    nativeCurrency: { name: string; symbol: string; decimals: number };
    faucets: string[];
    uniswapV4: { poolManager: Address; universalRouter: Address; quoter: Address; stateView: Address; positionManager: Address; permit2: Address };
  };
  walletAddChain: { chainId: string; chainName: string; rpcUrls: string[]; nativeCurrency: { name: string; symbol: string; decimals: number }; blockExplorerUrls: string[] };
  pool: { pairedCurrency: Address; fee: number; tickSpacing: number; initialPrice: string };
  deploymentBlock: number;
  integrations: { poolSwapTest: Address };
};

export type Runtime = Awaited<ReturnType<typeof loadRuntime>>;
export function safePath(path: string): boolean {
  return /^(?:[a-zA-Z0-9_-]+\/)*[a-zA-Z0-9_.-]+$/.test(path) && !path.split('/').some(p => p === '..' || p === '.');
}
async function fetchJson(path: string) {
  if (!safePath(path)) throw new Error('Unsafe deployment asset path.');
  const response = await fetch(new URL(path, new URL(import.meta.env.BASE_URL, window.location.href)), { cache: 'no-cache' });
  if (!response.ok) throw new Error(`Could not load ${path} (${response.status}). Reload to retry.`);
  return response.json();
}

export async function loadRuntime() {
  const deployment = await fetchJson('imd-deployment.json') as Deployment;
  if (deployment.version !== 1 || deployment.chainId !== deployment.network?.chainId ||
      Number(BigInt(deployment.walletAddChain.chainId)) !== deployment.chainId ||
      !deployment.network.testnet || !deployment.network.rpcUrls.length ||
      deployment.contracts.length !== 2) throw new Error('Deployment configuration is inconsistent. Actions are unavailable.');
  for (const address of [...deployment.contracts.map(c => c.address), ...Object.values(deployment.network.uniswapV4), deployment.integrations.poolSwapTest]) {
    if (!isAddress(address)) throw new Error('Invalid address in deployment configuration.');
  }
  const contracts = await Promise.all(deployment.contracts.map(async contract => {
    const abi = await fetchJson(contract.abiPath) as Abi;
    if (!Array.isArray(abi) || abiHash(abi) !== contract.abiHash) throw new Error(`${contract.name} ABI hash mismatch. Actions are unavailable.`);
    return { ...contract, abi };
  }));
  const hook = contracts.find(c => c.name === 'SwapLotteryHook');
  const token = contracts.find(c => c.name === 'Ticket');
  if (!hook || !token) throw new Error('Required contracts are missing.');
  const chain = defineChain({
    id: deployment.chainId, name: deployment.network.name, testnet: deployment.network.testnet,
    nativeCurrency: deployment.network.nativeCurrency,
    rpcUrls: { default: { http: deployment.network.rpcUrls } },
    blockExplorers: { default: { name: 'Explorer', url: deployment.network.explorer } },
  });
  const client = createPublicClient({ chain, transport: fallback(deployment.network.rpcUrls.map(url => http(url, { timeout: 6500, retryCount: 0 })), { retryCount: 0 }), batch: { multicall: false } });
  return { deployment, hook, token, chain, client };
}
