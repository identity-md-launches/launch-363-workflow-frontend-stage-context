import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import AxeBuilder from '@axe-core/playwright';
import { decodeFunctionData, encodeFunctionResult, encodeAbiParameters, encodeEventTopics, toHex, zeroAddress, parseEther } from 'viem';
import { routerAbi, stateAbi, quoterAbi, poolId } from '../src/protocol.ts';

const root = fileURLToPath(new URL('../..', import.meta.url));
const dist = resolve(root, 'dist');
const evidence = resolve(root, 'docs/evidence');
await mkdir(evidence, { recursive: true });
const manifest = JSON.parse(await readFile(resolve(dist, 'imd-deployment.json'), 'utf8'));
const contracts = await Promise.all(manifest.contracts.map(async c => ({ ...c, abi: JSON.parse(await readFile(resolve(dist, c.abiPath), 'utf8')) })));
const hook = contracts.find(c => c.name === 'SwapLotteryHook');
const token = contracts.find(c => c.name === 'Ticket');
const v4 = manifest.network.uniswapV4;
const router = manifest.integrations.poolSwapTest;
const account = '0x1111111111111111111111111111111111111111';
const other = '0x2222222222222222222222222222222222222222';
const hash = n => `0x${n.toString(16).padStart(64, '0')}`;
const key = { currency0: zeroAddress, currency1: token.address, fee: manifest.pool.fee, tickSpacing: manifest.pool.tickSpacing, hooks: hook.address };
const id = poolId(key);
const hour = BigInt(Math.floor(Date.now() / 3600000));
let state;
function reset(overrides = {}) {
  state = { block: BigInt(manifest.deploymentBlock) + 4000n, timestamp: hour * 3600n + 1000n, chain: 1, connected: false, account, allowance: 0n, winnings: parseEther('0.008'), previousStatus: 0, previousCount: 31n, target: 0n, missingCode: false, failReads: false, failQuote: false, failSimulation: false, rejectConnect: false, rejectSend: false, rejectSwitch: false, unknownChain: true, transactions: [], walletCalls: [], rpcCalls: [], ...overrides };
}
reset();
const block = () => ({ number: toHex(state.block), timestamp: toHex(state.timestamp), hash: hash(500), parentHash: hash(499), nonce: '0x0000000000000000', sha3Uncles: hash(1), logsBloom: `0x${'00'.repeat(256)}`, transactionsRoot: hash(1), stateRoot: hash(1), receiptsRoot: hash(1), miner: zeroAddress, difficulty: '0x0', totalDifficulty: '0x0', extraData: '0x', size: '0x1', gasLimit: '0x1c9c380', gasUsed: '0x0', baseFeePerGas: '0x1', transactions: [], uncles: [], mixHash: hash(1) });
const output = (abi, functionName, result) => encodeFunctionResult({ abi, functionName, result });
function decode(call) {
  const address = call.to.toLowerCase();
  const abi = address === hook.address ? hook.abi : address === token.address ? token.abi : address === router ? routerAbi : address === v4.stateView ? stateAbi : address === v4.quoter ? quoterAbi : undefined;
  if (!abi) throw new Error(`Unexpected contract ${address}`);
  return { abi, ...decodeFunctionData({ abi, data: call.data }) };
}
async function rpc(method, params = []) {
  state.rpcCalls.push({ method, params });
  if (state.failReads) throw { code: -32000, message: 'Mock RPC unavailable' };
  if (method === 'eth_chainId') return toHex(manifest.chainId);
  if (method === 'eth_getCode') return state.missingCode ? '0x' : '0x60006000';
  if (method === 'eth_getBlockByNumber') return block();
  if (method === 'eth_blockNumber') return toHex(state.block);
  if (method === 'eth_getBalance') return toHex(parseEther('5'));
  if (method === 'eth_getTransactionReceipt') return { transactionHash: params[0], transactionIndex: '0x0', blockHash: hash(500), blockNumber: toHex(state.block), from: account, to: state.transactions.at(-1)?.to ?? hook.address, cumulativeGasUsed: '0x5208', gasUsed: '0x5208', contractAddress: null, logs: [], logsBloom: `0x${'00'.repeat(256)}`, status: '0x1', effectiveGasPrice: '0x1', type: '0x2' };
  if (method === 'eth_getLogs') {
    const b = state.block - 100n;
    if (BigInt(params[0].fromBlock) > b || BigInt(params[0].toBlock) < b) return [];
    return [{ address: hook.address, blockHash: hash(480), blockNumber: toHex(b), transactionHash: hash(12), transactionIndex: '0x0', logIndex: '0x0', removed: false, data: encodeAbiParameters([{ type: 'uint256' }], [parseEther('0.024')]), topics: encodeEventTopics({ abi: hook.abi, eventName: 'Drawn', args: { poolId: id, round: hour - 2n, winner: other } }) }];
  }
  if (method === 'eth_call') {
    const { abi, functionName: f, args = [] } = decode(params[0]);
    if (['poolManager', 'manager'].includes(f)) return output(abi, f, v4.poolManager);
    if (f === 'currentRound') return output(abi, f, hour);
    if (f === 'ROUND_DURATION') return output(abi, f, 3600n);
    if (f === 'FEE_BPS') return output(abi, f, 50n);
    if (f === 'TICKET_THRESHOLD') return output(abi, f, parseEther('0.001'));
    if (f === 'decimals') return output(abi, f, 18);
    if (f === 'symbol') return output(abi, f, 'TIKT');
    if (f === 'balanceOf') return output(abi, f, parseEther('12000'));
    if (f === 'allowance') { assert.equal(args[1].toLowerCase(), router); return output(abi, f, state.allowance); }
    if (f === 'winnings') return output(abi, f, state.winnings);
    if (f === 'ticketsOf') return output(abi, f, args[2].toLowerCase() === account ? 3n : 1n);
    if (f === 'roundState') return output(abi, f, { status: args[1] === hour ? 0 : state.previousStatus, pot: args[1] === hour ? parseEther('0.0248') : parseEther('0.0132'), ticketCount: args[1] === hour ? 84n : state.previousCount, targetBlock: args[1] === hour ? 0n : state.target, winner: zeroAddress, rolledInto: state.previousStatus === 3 ? hour : 0n });
    if (f === 'getSlot0') { assert.equal(args[0], id); return output(abi, f, [BigInt(manifest.pool.initialPrice), 161160, 0, 3000]); }
    if (f === 'quoteExactInputSingle') {
      if (state.failQuote) throw { code: 3, message: 'execution reverted: NotEnoughLiquidity' };
      assert.equal(args[0].hookData.slice(-40).toLowerCase(), state.account.slice(2));
      return output(abi, f, [args[0].zeroForOne ? parseEther('9875') : parseEther('0.00001'), 120000n]);
    }
    if (['seal', 'draw', 'claim', 'swap', 'approve'].includes(f)) {
      if (state.failSimulation) throw { code: 3, message: 'execution reverted: PartialFill' };
      if (f === 'approve') return output(abi, f, true);
      if (f === 'swap') return output(abi, f, args[1].zeroForOne ? (-parseEther('0.001') << 128n) | parseEther('9875') : (parseEther('0.00001') << 128n) | BigInt.asUintN(128, -parseEther('100')));
      return '0x';
    }
    throw new Error(`Unhandled read ${f}`);
  }
  throw new Error(`Unhandled RPC method ${method}`);
}
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    if (!url.pathname.startsWith('/preview/')) { res.writeHead(404).end(); return; }
    const path = resolve(dist, decodeURIComponent(url.pathname.slice('/preview/'.length)) || 'index.html');
    if (!path.startsWith(`${dist}/`)) { res.writeHead(403).end(); return; }
    const bytes = await readFile(path);
    res.setHeader('Content-Type', ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json' })[extname(path)] || 'application/octet-stream');
    res.end(bytes);
  } catch { res.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}/preview/`;
const browser = await chromium.launch({ headless: true, executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE });
const results = [];
const resourceErrors = [];
const consoleErrors = [];
const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
const page = await context.newPage();
page.on('pageerror', error => consoleErrors.push(error.message));
page.on('console', msg => { if (msg.type() === 'error' && !msg.text().includes('net::ERR')) consoleErrors.push(msg.text()); });
page.on('requestfailed', req => { if (req.url().startsWith(url)) resourceErrors.push(req.url()); });
await context.route('https://**/*', async route => {
  assert(manifest.network.rpcUrls.some(url => new URL(url).href === route.request().url()), `Unexpected external resource: ${route.request().url()}`);
  const body = route.request().postDataJSON();
  async function handle(request) {
    try { return { jsonrpc: '2.0', id: request.id, result: await rpc(request.method, request.params) }; }
    catch (error) { return { jsonrpc: '2.0', id: request.id, error: { code: error.code ?? -32000, message: error.message } }; }
  }
  await route.fulfill({ contentType: 'application/json', body: JSON.stringify(Array.isArray(body) ? await Promise.all(body.map(handle)) : await handle(body)) });
});
await context.exposeBinding('walletRequest', async (_, request) => {
  state.walletCalls.push(request);
  const { method, params = [] } = request;
  try {
    if (method === 'eth_accounts') return { result: state.connected ? [state.account] : [] };
    if (method === 'eth_requestAccounts') { if (state.rejectConnect) throw { code: 4001, message: 'User rejected request' }; state.connected = true; return { result: [state.account] }; }
    if (method === 'eth_chainId') return { result: toHex(state.chain) };
    if (method === 'wallet_switchEthereumChain') {
      if (state.rejectSwitch) throw { code: 4001, message: 'User rejected request' };
      if (state.unknownChain) throw { code: 4902, message: 'Unknown chain' };
      state.chain = Number(BigInt(params[0].chainId)); return { result: null };
    }
    if (method === 'wallet_addEthereumChain') { assert.deepEqual(params[0], manifest.walletAddChain); state.unknownChain = false; return { result: null }; }
    if (method === 'eth_sendTransaction') {
      if (state.rejectSend) throw { code: 4001, message: 'User rejected request' };
      state.transactions.push(params[0]);
      const { functionName, args } = decode(params[0]);
      if (functionName === 'approve') { assert.equal(args[0].toLowerCase(), router); state.allowance = args[1]; }
      if (functionName === 'seal') { state.previousStatus = 1; state.target = state.block + 1n; }
      if (functionName === 'draw') {
        state.previousStatus = state.previousCount === 0n || state.block > state.target + 256n ? 3 : 2;
        state.block += 3n; // Receipt is ahead of the page's pre-transaction snapshot.
      }
      if (functionName === 'claim') state.winnings = 0n;
      return { result: hash(1000 + state.transactions.length) };
    }
    return { result: await rpc(method, params) };
  } catch (error) { return { error: { code: error.code ?? -32000, message: error.message } }; }
});
await context.addInitScript(() => {
  const listeners = {};
  window.ethereum = {
    isMetaMask: true,
    request: async request => { const response = await window.walletRequest(request); if (response.error) throw Object.assign(new Error(response.error.message), response.error); return response.result; },
    on: (event, fn) => { (listeners[event] ??= []).push(fn); },
    removeListener: (event, fn) => { listeners[event] = (listeners[event] ?? []).filter(item => item !== fn); },
    emit: (event, value) => { for (const listener of listeners[event] ?? []) listener(value); },
  };
});
const waitFor = async (selector, text) => { await page.locator(selector).filter({ hasText: text }).first().waitFor(); };
async function enabled(name, expected = true) {
  const control = page.getByRole('button', { name, exact: true });
  await control.waitFor();
  await page.waitForFunction(({ name, expected }) => [...document.querySelectorAll('button')].some(button => button.textContent.trim().replace(/\s*[↗↻]$/, '').trim() === name && button.disabled === !expected), { name, expected });
}
async function step(name, action) { await action(); results.push({ name, result: 'passed' }); console.log(`PASS ${name}`); }
const refresh = async () => { await enabled('Refresh'); await page.getByRole('button', { name: 'Refresh', exact: true }).click(); await enabled('Refresh'); };
const connect = async () => { await page.getByRole('button', { name: 'Connect wallet' }).click(); await waitFor('.transaction-region', 'Wallet connected'); };
try {
  await step('subpath assets, disconnected reads and action prerequisites', async () => {
    await page.goto(url);
    await waitFor('.sync-row', 'Live from block');
    assert.equal(await page.getByRole('heading', { level: 1 }).count(), 1);
    assert(await page.getByRole('button', { name: 'Get quote', exact: true }).isDisabled());
    assert(await page.getByRole('button', { name: 'Seal round', exact: true }).isDisabled());
    assert(await page.getByRole('button', { name: 'Claim winnings' }).isDisabled());
    assert((await page.locator('.pot-amount').innerText()).includes('0.0248'));
    await waitFor('.winner-list', '0.024 ETH');
  });
  await step('wallet rejection is recoverable', async () => {
    state.rejectConnect = true;
    await page.getByRole('button', { name: 'Connect wallet' }).click();
    await waitFor('[role="alert"]', 'Request declined');
    assert.equal(state.transactions.length, 0);
    state.rejectConnect = false;
  });
  await step('wrong chain offers exact add-chain fallback and switches again', async () => {
    await connect();
    assert(await page.getByRole('button', { name: 'Get quote', exact: true }).isDisabled());
    await page.getByRole('button', { name: 'Switch to Sepolia', exact: true }).click();
    await enabled('Get quote');
    const switches = state.walletCalls.filter(call => call.method.startsWith('wallet_'));
    assert.deepEqual(switches.map(call => call.method), ['wallet_switchEthereumChain', 'wallet_addEthereumChain', 'wallet_switchEthereumChain']);
    await waitFor('.round-metrics', '3');
  });
  await step('strict form validation and quotes use the configured quoter', async () => {
    await page.getByLabel('You pay').fill('0');
    await page.getByRole('button', { name: 'Get quote', exact: true }).click();
    await waitFor('#trade-error', 'positive amount');
    assert.equal(await page.locator('#amount').evaluate(el => document.activeElement === el), true);
    await page.getByLabel('You pay').fill('0.001');
    await page.getByRole('button', { name: 'Get quote', exact: true }).click();
    await enabled('Confirm buy TIKT');
    assert((await page.locator('.receive-box').innerText()).includes('9,875'));
    assert(state.rpcCalls.some(call => call.method === 'eth_call' && call.params[0].to === v4.quoter));
  });
  await step('simulation revert prevents a wallet transaction', async () => {
    state.failSimulation = true;
    await page.getByRole('button', { name: 'Confirm buy TIKT' }).click();
    await waitFor('[role="alert"]', 'PartialFill');
    assert.equal(state.transactions.length, 0);
    state.failSimulation = false;
  });
  await step('exact-input buy encodes account and native value through PoolSwapTest', async () => {
    await enabled('Confirm buy TIKT');
    await page.getByRole('button', { name: 'Confirm buy TIKT' }).click();
    await waitFor('.transaction-region', 'Transaction confirmed');
    const transaction = state.transactions.at(-1);
    assert.equal(transaction.to, router);
    assert.equal(BigInt(transaction.value), parseEther('0.001'));
    const decoded = decode(transaction);
    assert.equal(decoded.args[1].zeroForOne, true);
    assert.equal(decoded.args[1].amountSpecified, -parseEther('0.001'));
    assert.equal(decoded.args[3].slice(-40), account.slice(2));
    assert.deepEqual(decoded.args[2], { takeClaims: false, settleUsingBurn: false });
  });
  await step('sell has an explicit exact-amount approval followed by a fresh quote and sell', async () => {
    await enabled('Get quote');
    await page.getByRole('button', { name: 'Sell TIKT', exact: true }).click();
    await page.getByRole('button', { name: 'Get quote', exact: true }).click();
    await enabled('Approve TIKT');
    await page.getByRole('button', { name: 'Approve TIKT' }).click();
    await waitFor('.transaction-region', 'Approval confirmed');
    const approval = decode(state.transactions.at(-1));
    assert.equal(approval.functionName, 'approve');
    assert.equal(approval.args[1], parseEther('100'));
    await enabled('Get quote');
    await page.getByRole('button', { name: 'Get quote', exact: true }).click();
    await enabled('Confirm sell TIKT');
    await page.getByRole('button', { name: 'Confirm sell TIKT' }).click();
    await waitFor('.transaction-region', 'Transaction confirmed');
    const transaction = state.transactions.at(-1);
    assert.equal(BigInt(transaction.value ?? '0x0'), 0n);
    assert.equal(decode(transaction).args[1].zeroForOne, false);
    assert.equal(transaction.to, router);
  });
  await step('seal, target block wait, draw and claim complete through the real page controls', async () => {
    await enabled('Seal round');
    await page.getByRole('button', { name: 'Seal round' }).click();
    await waitFor('.round-guidance', 'Wait until block');
    assert(await page.getByRole('button', { name: 'Draw winner' }).isDisabled());
    assert.equal(decode(state.transactions.at(-1)).functionName, 'seal');
    state.block = state.target + 1n;
    await refresh();
    await enabled('Draw winner');
    await page.getByRole('button', { name: 'Draw winner' }).click();
    await waitFor('.round-panel .pill', 'Drawn');
    await waitFor('.history-footer', state.block.toLocaleString('en-US'));
    await enabled('Claim winnings');
    await page.getByRole('button', { name: 'Claim winnings' }).click();
    await waitFor('.claim-panel', 'No winnings to claim yet');
    assert(await page.getByRole('button', { name: 'Claim winnings' }).isDisabled());
    assert.equal(decode(state.transactions.at(-1)).functionName, 'claim');
  });
  await step('expired round exposes rollover and historical round selector works', async () => {
    state.previousStatus = 1; state.target = state.block - 257n;
    await refresh();
    await enabled('Roll over pot');
    await page.getByRole('button', { name: 'Roll over pot' }).click();
    await waitFor('.round-guidance', 'Pot rolled into round');
    await page.getByLabel('UTC round number').fill((hour - 3n).toString());
    await page.getByRole('button', { name: 'Load round', exact: true }).click();
    await waitFor('.round-time', `Round ${hour - 3n}`);
    await page.getByRole('button', { name: 'Previous hour' }).click();
    await waitFor('.round-time', `Round ${hour - 1n}`);
    await page.getByRole('button', { name: 'Load older blocks' }).click();
    await enabled('Load older blocks');
    await page.getByRole('button', { name: 'Load older blocks' }).click();
    await waitFor('.history-footer', '11,791,413');
  });
  await step('account changes invalidate quotes and read the new wallet', async () => {
    await page.getByRole('button', { name: 'Buy TIKT', exact: true }).click();
    await page.getByRole('button', { name: 'Get quote', exact: true }).click();
    await enabled('Confirm buy TIKT');
    state.account = other;
    await page.evaluate(account => window.ethereum.emit('accountsChanged', [account]), other);
    await enabled('Get quote');
    assert.equal(await page.getByRole('button', { name: 'Confirm buy TIKT' }).count(), 0);
    assert((await page.locator('.account').innerText()).includes('0x2222'));
    state.account = account;
    await page.evaluate(account => window.ethereum.emit('accountsChanged', [account]), account);
    await enabled('Get quote');
  });
  await step('missing code blocks actions and recovery re-enables them', async () => {
    state.missingCode = true;
    await refresh();
    await waitFor('[role="alert"]', 'no code');
    assert(await page.getByRole('button', { name: 'Get quote', exact: true }).isDisabled());
    state.missingCode = false;
    await refresh();
    await enabled('Get quote');
  });
  await step('quote failure displays a recoverable error', async () => {
    state.failQuote = true;
    await page.getByRole('button', { name: 'Get quote', exact: true }).click();
    await waitFor('#trade-error', 'NotEnoughLiquidity');
    assert.equal(await page.getByRole('button', { name: 'Confirm buy TIKT' }).count(), 0);
    state.failQuote = false;
    await page.getByLabel('You pay').fill('0.002');
  });
  await step('wallet rejection, expired quote and disconnect cannot submit a swap', async () => {
    await page.getByRole('button', { name: 'Get quote', exact: true }).click();
    await enabled('Confirm buy TIKT');
    const count = state.transactions.length;
    state.rejectSend = true;
    await page.getByRole('button', { name: 'Confirm buy TIKT' }).click();
    await waitFor('[role="alert"]', 'Request declined');
    assert.equal(state.transactions.length, count);
    state.rejectSend = false;
    await page.clock.install();
    await page.clock.fastForward(31000);
    await waitFor('.receive-box', 'Quote expired');
    assert(await page.getByRole('button', { name: 'Confirm buy TIKT' }).isDisabled());
    state.connected = false;
    await page.evaluate(() => window.ethereum.emit('accountsChanged', []));
    await enabled('Connect wallet');
    assert(await page.getByRole('button', { name: 'Get quote', exact: true }).isDisabled());
    assert.equal(await page.getByRole('button', { name: 'Confirm buy TIKT' }).count(), 0);
    await connect();
    await enabled('Get quote');
  });
  await step('RPC failure pauses actions and Refresh recovers', async () => {
    state.failReads = true;
    await refresh();
    await waitFor('.sync-row', 'Connection interrupted');
    assert(await page.getByRole('button', { name: 'Get quote', exact: true }).isDisabled());
    state.failReads = false;
    await refresh();
    await enabled('Get quote');
  });
  await step('responsive screenshots, keyboard focus, axe and contrast at representative widths', async () => {
    state.previousStatus = 0; state.winnings = parseEther('0.008');
    await refresh();
    const views = [];
    for (const width of [1440, 768, 390, 320]) {
      await page.setViewportSize({ width, height: 1000 });
      const layout = await page.evaluate(() => ({ scroll: document.documentElement.scrollWidth, viewport: innerWidth }));
      assert(layout.scroll <= layout.viewport, `Overflow at ${width}: ${JSON.stringify(layout)}`);
      const scan = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa']).analyze();
      views.push({ width, overflow: false, violations: scan.violations.map(v => ({ id: v.id, impact: v.impact, nodes: v.nodes.map(n => n.target) })) });
      assert.equal(scan.violations.length, 0, JSON.stringify(scan.violations.map(v => ({ id: v.id, nodes: v.nodes.map(n => n.target) }))));
      if ([1440, 390, 320].includes(width)) await page.screenshot({ path: resolve(evidence, `mocked-${width}.webp`), fullPage: true, type: 'webp' });
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.keyboard.press('Control+Home');
    await page.evaluate(() => { document.activeElement?.blur(); document.body.focus(); });
    await page.keyboard.press('Tab');
    const keyboard = await page.evaluate(() => ({ tag: document.activeElement?.tagName, text: document.activeElement?.textContent, outline: getComputedStyle(document.activeElement).outlineWidth }));
    assert.equal(keyboard.outline, '3px');
    await page.screenshot({ path: resolve(evidence, 'keyboard-focus.webp'), type: 'webp' });
    const contrasts = await page.evaluate(() => {
      const luminance = css => {
        const values = css.match(/[\d.]+/g).slice(0, 3).map(Number).map(v => { const s = v / 255; return s <= .04045 ? s / 12.92 : ((s + .055) / 1.055) ** 2.4; });
        return values[0] * .2126 + values[1] * .7152 + values[2] * .0722;
      };
      return ['.pot-caption', '.intro-note p', '.router-note', '.claim-panel p', '.how-grid p', '.button.primary'].map(selector => {
        const element = document.querySelector(selector);
        const foreground = getComputedStyle(element).color;
        let surface = element;
        while (getComputedStyle(surface).backgroundColor === 'rgba(0, 0, 0, 0)' && surface.parentElement) surface = surface.parentElement;
        const background = getComputedStyle(surface).backgroundColor;
        const a = luminance(foreground), b = luminance(background);
        return { selector, foreground, background, ratio: (Math.max(a, b) + .05) / (Math.min(a, b) + .05) };
      });
    });
    assert(contrasts.every(pair => pair.ratio >= 4.5));
    await page.emulateMedia({ reducedMotion: 'reduce' });
    assert.equal(await page.locator('.primary').evaluate(el => getComputedStyle(el).transitionDuration), '0s');
    await page.evaluate(() => { document.documentElement.style.fontSize = '200%'; });
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await page.evaluate(() => { document.documentElement.style.fontSize = ''; });
    await writeFile(resolve(evidence, 'accessibility.json'), JSON.stringify({ views, keyboard, contrasts, reducedMotion: 'No button transitions', textEnlargement: '200% root font size; no overflow at 1440px; not native browser zoom' }, null, 2) + '\n');
  });
  await step('no unexpected static resource or browser console failures', async () => {
    assert.deepEqual(resourceErrors, []);
    assert.deepEqual(consoleErrors, []);
  });
  await writeFile(resolve(evidence, 'interactions.json'), JSON.stringify({ checkedAt: new Date().toISOString(), exportBase: '/preview/', mockedWalletAndRpc: true, realTransactionsSent: 0, results, transactionFunctions: state.transactions.map(tx => decode(tx).functionName), consoleErrors, resourceErrors }, null, 2) + '\n');
} catch (error) {
  await page.screenshot({ path: resolve(root, 'test/scratch/browser-failure.png'), fullPage: true });
  await writeFile(resolve(root, 'test/scratch/browser-failure.txt'), (await page.locator('body').innerText()) + '\n' + error.stack);
  throw error;
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
