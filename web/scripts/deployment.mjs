import { readFile, writeFile, mkdir, readdir, stat, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve, relative, sep } from 'node:path';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { abiHash, canonical } from '../src/canonical.ts';

const web = fileURLToPath(new URL('..', import.meta.url));
const root = resolve(web, '..');
const output = resolve(root, 'dist');
const json = async path => JSON.parse(await readFile(path, 'utf8'));
const handoff = await json(resolve(web, 'deployment/handoff.json'));
const networkInput = await json(resolve(web, 'deployment/network.json'));
const integrations = await json(resolve(web, 'deployment/integration.json'));
const mode = process.argv[2];
assert.equal(handoff.version, 1);
assert.equal(handoff.chainId, networkInput.network.chainId);
assert.equal(Number(BigInt(networkInput.walletAddChain.chainId)), handoff.chainId);
assert.match(handoff.sourceCommit, /^[0-9a-f]{40}$/);
assert.match(handoff.attestationHash, /^[0-9a-f]{64}$/);
assert.equal(handoff.manifest.pool.pairedCurrency, '0x0000000000000000000000000000000000000000');
assert.deepEqual(handoff.contracts.map(c => c.name).sort(), ['SwapLotteryHook', 'Ticket']);
const contracts = handoff.contracts.map(({ name, address, abiHash }) => ({ name, address, abiHash, abiPath: `abi/${name}.json` }));
const config = {
  version: 1,
  launchId: handoff.launchId,
  chainId: handoff.chainId,
  sourceCommit: handoff.sourceCommit,
  attestationHash: handoff.attestationHash,
  contracts,
  assets: [],
  network: networkInput.network,
  walletAddChain: networkInput.walletAddChain,
  pool: handoff.manifest.pool,
  deploymentBlock: Math.min(...handoff.contracts.map(c => c.blockNumber)),
  integrations,
};
const pretty = value => JSON.stringify(value, null, 2) + '\n';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');

async function inventory(dir) {
  const files = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    assert(!entry.isSymbolicLink(), 'No symlinks in the export');
    const path = resolve(dir, entry.name);
    if (entry.isDirectory()) files.push(...await inventory(path));
    else if (path !== resolve(output, 'imd-deployment.json')) files.push(path);
  }
  return files.sort();
}

if (mode === 'prepare') {
  // git show binds exports to the deployed commit, not a mutable working tree.
  const generated = resolve(web, 'generated');
  await rm(generated, { recursive: true, force: true });
  await mkdir(resolve(generated, 'abi'), { recursive: true });
  for (const contract of contracts) {
    const bytes = execFileSync('git', ['show', `${handoff.sourceCommit}:docs/abi/${contract.name}.json`], { cwd: root });
    const abi = JSON.parse(bytes);
    assert(Array.isArray(abi), 'Expected a raw ABI array');
    assert.equal(abiHash(abi), contract.abiHash, `${contract.name} ABI mismatch`);
    await writeFile(resolve(generated, contract.abiPath), bytes);
    console.log(`${contract.name}: pinned ABI verified (${contract.abiHash})`);
  }
  await writeFile(resolve(generated, 'imd-deployment.json'), pretty(config));
} else if (mode === 'manifest' || mode === 'verify') {
  const files = await inventory(output);
  assert(files.length <= 128);
  let total = 0;
  for (const file of files) {
    const bytes = await readFile(file);
    assert(bytes.length <= 8388608);
    total += bytes.length;
    config.assets.push({ path: relative(output, file).split(sep).join('/'), sha256: sha(bytes) });
  }
  assert(config.assets.some(asset => asset.path === 'index.html'));
  assert(total < 8 * 1024 * 1024, 'Keep space within the complete submission budget');
  for (const contract of contracts) {
    assert.equal(abiHash(await json(resolve(output, contract.abiPath))), contract.abiHash);
    assert.equal(sha(await readFile(resolve(output, contract.abiPath))), sha(execFileSync('git', ['show', `${handoff.sourceCommit}:docs/abi/${contract.name}.json`], { cwd: root })));
  }
  if (mode === 'manifest') await writeFile(resolve(output, 'imd-deployment.json'), pretty(config));
  else assert.equal(canonical(await json(resolve(output, 'imd-deployment.json'))), canonical(config));
  console.log(`${mode}: ${files.length} assets, ${total} bytes; handoff, network, pinned ABI bytes and inventory verified.`);
} else throw new Error('Use prepare, manifest or verify');
