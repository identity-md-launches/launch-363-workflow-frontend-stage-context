import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { createPublicClient, defineChain, http } from 'viem';
import { verifyChain, readSnapshot, keyFor } from '../src/chain.ts';
import { identity, poolId, quoterAbi } from '../src/protocol.ts';

const base = new URL('../../dist/', import.meta.url);
const deployment = JSON.parse(await readFile(new URL('imd-deployment.json', base), 'utf8'));
const contracts = await Promise.all(deployment.contracts.map(async c => ({ ...c, abi: JSON.parse(await readFile(new URL(c.abiPath, base), 'utf8')) })));
const chain = defineChain({ id: deployment.chainId, name: deployment.network.name, nativeCurrency: deployment.network.nativeCurrency, rpcUrls: { default: { http: deployment.network.rpcUrls } } });
const evidence = { checkedAt: new Date().toISOString(), chainId: chain.id, sourceCommit: deployment.sourceCommit, broadcastTransactions: false, endpoints: [] };
for (const url of deployment.network.rpcUrls) {
  const client = createPublicClient({ chain, transport: http(url, { timeout: 8000, retryCount: 0 }) });
  const runtime = { deployment, chain, client, hook: contracts.find(c => c.name === 'SwapLotteryHook'), token: contracts.find(c => c.name === 'Ticket') };
  const result = { url };
  try {
    await verifyChain(runtime);
    result.chainCodeAndManagers = 'passed';
    const snapshot = await readSnapshot(runtime);
    result.snapshot = snapshot;
    result.poolId = poolId(keyFor(runtime));
    try {
      const quoted = await client.simulateContract({ address: deployment.network.uniswapV4.quoter, abi: quoterAbi, functionName: 'quoteExactInputSingle', args: [{ poolKey: keyFor(runtime), zeroForOne: true, exactAmount: 1000000000000000n, hookData: identity(runtime.token.address) }] });
      result.readOnlyBuyQuote = quoted.result;
    } catch (error) { result.quoteError = error.shortMessage || error.message; }
  } catch (error) { result.error = error.shortMessage || error.message; }
  evidence.endpoints.push(result);
  console.log(JSON.stringify(result, (_, value) => typeof value === 'bigint' ? value.toString() : value, 2));
}
await mkdir(new URL('../../docs/evidence/', import.meta.url), { recursive: true });
await writeFile(new URL('../../docs/evidence/live-rpc.json', import.meta.url), JSON.stringify(evidence, (_, value) => typeof value === 'bigint' ? value.toString() : value, 2) + '\n');
