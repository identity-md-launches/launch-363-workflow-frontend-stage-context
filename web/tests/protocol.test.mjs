import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { decodeAbiParameters, decodeFunctionData, encodeFunctionData, zeroAddress } from 'viem';
import { abiHash } from '../src/canonical.ts';
import { amountUnits, priceLimit, roundAction, swapParams, routerAbi, deltaOutput } from '../src/protocol.ts';
import { switchChain } from '../src/chain.ts';

const account = '0x1111111111111111111111111111111111111111';
const key = { currency0: zeroAddress, currency1: account, fee: 3000, tickSpacing: 60, hooks: '0x2222222222222222222222222222222222222222' };
const round = { status: 0, pot: 0n, ticketCount: 1n, targetBlock: 100n, winner: zeroAddress, rolledInto: 0n };

test('attested implementation ABI hashes match the committed export', async () => {
  const manifest = JSON.parse(await readFile(new URL('../../dist/imd-deployment.json', import.meta.url), 'utf8'));
  for (const contract of manifest.contracts) {
    const abi = JSON.parse(await readFile(new URL(`../../dist/${contract.abiPath}`, import.meta.url), 'utf8'));
    assert.equal(abiHash(abi), contract.abiHash);
  }
});
test('strict amounts reject zero, negatives, exponent notation and excess precision', () => {
  for (const value of ['0', '-1', '1e3', '.1', '1.', 'abc', '0.0000001']) assert.throws(() => amountUnits(value, 6));
  assert.equal(amountUnits('0.001', 18), 10n ** 15n);
  assert.equal(amountUnits('1.123456', 6), 1123456n);
});
test('round eligibility follows all target-block boundary rules', () => {
  assert.equal(roundAction(round, 4n, 4n, 100n), 'open');
  assert.equal(roundAction(round, 3n, 4n, 100n), 'seal');
  const sealed = { ...round, status: 1 };
  assert.equal(roundAction(sealed, 3n, 4n, 100n), 'wait');
  assert.equal(roundAction(sealed, 3n, 4n, 101n), 'draw');
  assert.equal(roundAction(sealed, 3n, 4n, 356n), 'draw');
  assert.equal(roundAction(sealed, 3n, 4n, 357n), 'rollover');
  assert.equal(roundAction({ ...sealed, ticketCount: 0n }, 3n, 4n, 101n), 'rollover');
  for (const status of [2, 3]) assert.equal(roundAction({ ...round, status }, 3n, 4n, 101n), 'finished');
});
test('conservative price limits use bigint math for both directions', () => {
  const price = 250178251749461638198017379368160n;
  const buy = priceLimit(price, true, '1');
  const sell = priceLimit(price, false, '1');
  assert(buy < price && sell > price);
  assert(buy * buy >= price * price * 9900n / 10000n);
  assert(sell * sell <= price * price * 10100n / 10000n);
  for (const input of ['0', '0.09', '5.01', '100', '-1']) assert.throws(() => priceLimit(price, true, input));
});
test('router encoding preserves exact input, wallet identity, price limit and settlement modes', () => {
  for (const buy of [true, false]) {
    const args = swapParams(key, account, 1000n, buy, 2n ** 96n);
    const call = decodeFunctionData({ abi: routerAbi, data: encodeFunctionData({ abi: routerAbi, functionName: 'swap', args }) });
    assert.equal(call.functionName, 'swap');
    assert.equal(call.args[1].amountSpecified, -1000n);
    assert.equal(call.args[1].zeroForOne, buy);
    assert.equal(call.args[1].sqrtPriceLimitX96, 2n ** 96n);
    assert.deepEqual(call.args[2], { takeClaims: false, settleUsingBurn: false });
    assert.equal(decodeAbiParameters([{ type: 'address' }], call.args[3])[0].toLowerCase(), account);
  }
  assert.equal(deltaOutput((-1000n << 128n) | 900n, true), 900n);
  assert.equal(deltaOutput((900n << 128n) | BigInt.asUintN(128, -1000n), false), 900n);
});
test('unknown-chain switch adds exact parameters then switches again', async () => {
  const walletAddChain = { chainId: '0xaa36a7', chainName: 'Sepolia', rpcUrls: ['https://example.invalid'] };
  const calls = [];
  const provider = { request: async call => { calls.push(call); if (calls.length === 1) throw { code: 4902 }; } };
  await switchChain(provider, { deployment: { walletAddChain } });
  assert.deepEqual(calls.map(call => call.method), ['wallet_switchEthereumChain', 'wallet_addEthereumChain', 'wallet_switchEthereumChain']);
  assert.deepEqual(calls[1].params, [walletAddChain]);
});
test('rejected chain switching does not add a chain', async () => {
  const calls = [];
  await assert.rejects(switchChain({ request: async call => { calls.push(call); throw { code: 4001 }; } }, { deployment: { walletAddChain: { chainId: '0xaa36a7' } } }));
  assert.equal(calls.length, 1);
});
