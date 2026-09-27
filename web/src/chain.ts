import { createPublicClient, custom, type Address, type EIP1193Provider, type Hex, type PublicClient, type Transport } from 'viem';
import type { Runtime } from './config';
import { poolId, quoterAbi, routerAbi, stateAbi, type PoolKey, type Round } from './protocol';

export type BrowserWallet = EIP1193Provider & { providers?: BrowserWallet[]; isMetaMask?: boolean; isCoinbaseWallet?: boolean };
declare global { interface Window { ethereum?: BrowserWallet } }
export type WalletChoice = { id: string; name: string; provider: BrowserWallet };
export type Snapshot = {
  round: bigint; current: Round; selectedId: bigint; selected: Round; block: bigint; timestamp: bigint;
  sqrtPrice: bigint; decimals: number; symbol: string; owned: bigint; winnings: bigint;
  tokenBalance: bigint; ethBalance: bigint; allowance: bigint; fetchedAt: number; account?: Address;
  feeBps: bigint; threshold: bigint; duration: bigint;
};
export type Winner = { round: bigint; winner: Address; pot: bigint; hash: Hex; block: bigint; logIndex: number };
export type ReadClient = PublicClient<Transport, Runtime['chain']>;
export const keyFor = (runtime: Runtime): PoolKey => ({
  currency0: runtime.deployment.pool.pairedCurrency, currency1: runtime.token.address,
  fee: runtime.deployment.pool.fee, tickSpacing: runtime.deployment.pool.tickSpacing, hooks: runtime.hook.address,
});
export function walletReadClient(runtime: Runtime, provider?: BrowserWallet) {
  return provider ? createPublicClient({ chain: runtime.chain, transport: custom(provider, { retryCount: 0 }) }) : undefined;
}
export async function withReadFallback<T>(runtime: Runtime, provider: BrowserWallet | undefined, action: (client: ReadClient) => Promise<T>): Promise<T> {
  try { return await action(runtime.client); }
  catch (original) {
    const wallet = walletReadClient(runtime, provider);
    if (!wallet || await wallet.getChainId() !== runtime.chain.id) throw original;
    return action(wallet);
  }
}
export async function verifyChain(runtime: Runtime, client: ReadClient = runtime.client) {
  if (await client.getChainId() !== runtime.chain.id) throw new Error('RPC returned the wrong chain. Retry with a connected Sepolia wallet.');
  const { deployment, hook, token } = runtime;
  const v4 = deployment.network.uniswapV4;
  const addresses = [hook.address, token.address, v4.poolManager, v4.stateView, v4.quoter, deployment.integrations.poolSwapTest];
  const codes = await Promise.all(addresses.map(address => client.getCode({ address })));
  if (codes.some(code => !code || code === '0x')) throw new Error('A configured contract has no code. Actions are unavailable.');
  const managers = await Promise.all([
    client.readContract({ address: hook.address, abi: hook.abi, functionName: 'poolManager' }),
    client.readContract({ address: deployment.integrations.poolSwapTest, abi: routerAbi, functionName: 'manager' }),
    client.readContract({ address: v4.stateView, abi: stateAbi, functionName: 'poolManager' }),
    client.readContract({ address: v4.quoter, abi: quoterAbi, functionName: 'poolManager' }),
  ]);
  if (managers.some(manager => String(manager).toLowerCase() !== v4.poolManager.toLowerCase())) throw new Error('A contract points to a different PoolManager. Actions are unavailable.');
}

export async function readSnapshot(runtime: Runtime, account?: Address, selected?: bigint, client: ReadClient = runtime.client): Promise<Snapshot> {
  const block = await client.getBlock();
  const blockNumber = block.number;
  const hookRead = (functionName: string, args: unknown[] = []) => client.readContract({ address: runtime.hook.address, abi: runtime.hook.abi, functionName, args, blockNumber });
  const tokenRead = (functionName: string, args: unknown[] = []) => client.readContract({ address: runtime.token.address, abi: runtime.token.abi, functionName, args, blockNumber });
  const [round, duration, feeBps, threshold, decimals, symbol] = await Promise.all([
    hookRead('currentRound'), hookRead('ROUND_DURATION'), hookRead('FEE_BPS'), hookRead('TICKET_THRESHOLD'), tokenRead('decimals'), tokenRead('symbol'),
  ]) as [bigint, bigint, bigint, bigint, number, string];
  const selectedId = selected ?? round - 1n;
  const id = poolId(keyFor(runtime));
  const [current, selectedRound, slot, owned, winnings, tokenBalance, ethBalance, allowance] = await Promise.all([
    hookRead('roundState', [id, round]), hookRead('roundState', [id, selectedId]),
    client.readContract({ address: runtime.deployment.network.uniswapV4.stateView, abi: stateAbi, functionName: 'getSlot0', args: [id], blockNumber }),
    account ? hookRead('ticketsOf', [id, round, account]) : 0n,
    account ? hookRead('winnings', [account]) : 0n,
    account ? tokenRead('balanceOf', [account]) : 0n,
    account ? client.getBalance({ address: account, blockNumber }) : 0n,
    account ? tokenRead('allowance', [account, runtime.deployment.integrations.poolSwapTest]) : 0n,
  ]);
  if (slot[0] === 0n) throw new Error('The pool is not initialized. Retry after checking the deployment.');
  return {
    round, current: current as Round, selectedId, selected: selectedRound as Round, block: blockNumber, timestamp: block.timestamp,
    sqrtPrice: slot[0], decimals, symbol, owned: owned as bigint, winnings: winnings as bigint,
    tokenBalance: tokenBalance as bigint, ethBalance: ethBalance as bigint, allowance: allowance as bigint, fetchedAt: Date.now(), account,
    feeBps, threshold, duration,
  };
}

export async function readWinners(runtime: Runtime, fromBlock: bigint, toBlock: bigint, client: ReadClient = runtime.client): Promise<Winner[]> {
  if (fromBlock > toBlock) return [];
  try {
    const logs = await client.getContractEvents({ address: runtime.hook.address, abi: runtime.hook.abi, eventName: 'Drawn', args: { poolId: poolId(keyFor(runtime)) }, fromBlock, toBlock, strict: true });
    return logs.map(log => {
      const args = log.args as unknown as { round: bigint; winner: Address; pot: bigint };
      return { ...args, hash: log.transactionHash, block: log.blockNumber, logIndex: log.logIndex };
    });
  } catch (error) {
    // Public RPCs have different getLogs range caps; split bounded pages on failure.
    if (toBlock - fromBlock < 125n) throw error;
    const midpoint = (toBlock + fromBlock) / 2n;
    return [...await readWinners(runtime, fromBlock, midpoint, client), ...await readWinners(runtime, midpoint + 1n, toBlock, client)];
  }
}
export async function switchChain(provider: BrowserWallet, runtime: Runtime) {
  const params: [{ chainId: string }] = [{ chainId: runtime.deployment.walletAddChain.chainId }];
  try { await provider.request({ method: 'wallet_switchEthereumChain', params }); }
  catch (error) {
    const e = error as { code?: number; message?: string; cause?: { code?: number }; data?: { originalError?: { code?: number } } };
    if (e.code !== 4902 && e.cause?.code !== 4902 && e.data?.originalError?.code !== 4902 && !/unknown chain|unrecognized chain|chain.*not.*(added|configured)/i.test(e.message ?? '')) throw error;
    await provider.request({ method: 'wallet_addEthereumChain', params: [runtime.deployment.walletAddChain] });
    await provider.request({ method: 'wallet_switchEthereumChain', params });
  }
}
export function errorMessage(error: unknown): string {
  const e = error as { code?: number; shortMessage?: string; message?: string };
  if (e?.code === 4001 || /user rejected|user denied/i.test(e?.message ?? '')) return 'Request declined in your wallet. Nothing was submitted; try again when ready.';
  return e?.shortMessage || e?.message || 'Request failed. Check your connection and try again.';
}
