import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react';
import { createWalletClient, custom, formatUnits, type Abi, type Address, type Hex } from 'viem';
import { loadRuntime, type Runtime } from './config';
import { errorMessage, keyFor, readSnapshot, readWinners, switchChain, verifyChain, withReadFallback, type BrowserWallet, type Snapshot, type WalletChoice, type Winner } from './chain';
import { amountUnits, deltaOutput, identity, poolId, priceLimit, quoterAbi, roundAction, routerAbi, swapParams } from './protocol';

const short = (value: string) => `${value.slice(0, 6)}…${value.slice(-4)}`;
const number = (value: bigint, decimals = 18, places = 6) => {
  const raw = formatUnits(value, decimals);
  const [whole, fraction = ''] = raw.split('.');
  if (value > 0n && whole === '0' && !/[1-9]/.test(fraction.slice(0, places))) return `<0.${'0'.repeat(places - 1)}1`;
  return `${Number(whole).toLocaleString('en-US')}${fraction ? `.${fraction.slice(0, places).replace(/0+$/, '') || '0'}` : ''}`;
};
const roundDate = (id: bigint) => new Intl.DateTimeFormat('en', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: 'UTC', hour12: false }).format(new Date(Number(id) * 3600000));
type Quote = { amount: bigint; output: bigint; limit: bigint; expires: number; account: Address; buy: boolean; input: string; percent: string };

function External({ href, children, title }: { href: string; children: React.ReactNode; title?: string }) {
  return <a href={href} target="_blank" rel="noreferrer" title={title}>{children}<span aria-hidden="true"> ↗</span></a>;
}
function TicketMark() {
  return <svg viewBox="0 0 32 24" fill="none" aria-hidden="true"><path d="M2 2h28v6a4 4 0 0 0 0 8v6H2v-6a4 4 0 0 0 0-8V2Z" stroke="currentColor" strokeWidth="2"/><path d="M21 3v18" stroke="currentColor" strokeWidth="2" strokeDasharray="3 3"/></svg>;
}

export default function App() {
  const [runtime, setRuntime] = useState<Runtime>();
  const [configError, setConfigError] = useState('');
  const [wallets, setWallets] = useState<WalletChoice[]>([]);
  const [walletId, setWalletId] = useState('');
  const provider = wallets.find(wallet => wallet.id === walletId)?.provider;
  const [account, setAccount] = useState<Address>();
  const [walletChain, setWalletChain] = useState<number>();
  const [snapshot, setSnapshot] = useState<Snapshot>();
  const [verified, setVerified] = useState(false);
  const [readError, setReadError] = useState('');
  const [reading, setReading] = useState(false);
  const [reload, setReload] = useState(0);
  const [selectedRound, setSelectedRound] = useState<bigint>();
  const [roundInput, setRoundInput] = useState('');
  const [roundError, setRoundError] = useState('');
  const [winners, setWinners] = useState<Winner[]>([]);
  const [eventStart, setEventStart] = useState<bigint>();
  const [eventEnd, setEventEnd] = useState<bigint>();
  const [eventsAfterBlock, setEventsAfterBlock] = useState<bigint>();
  const [eventError, setEventError] = useState('');
  const [eventsLoading, setEventsLoading] = useState(false);
  const [buy, setBuy] = useState(true);
  const [input, setInput] = useState('0.001');
  const [percent, setPercent] = useState('1');
  const [quote, setQuote] = useState<Quote>();
  const [formError, setFormError] = useState('');
  const [busy, setBusy] = useState('');
  const [status, setStatus] = useState('');
  const [actionError, setActionError] = useState('');
  const [tx, setTx] = useState<Hex>();
  const [now, setNow] = useState(Date.now());
  const revision = useRef(0);
  const activeWallet = useRef({ provider, account, walletChain });
  activeWallet.current = { provider, account, walletChain };

  useEffect(() => { loadRuntime().then(setRuntime).catch(error => setConfigError(errorMessage(error))); }, []);
  useEffect(() => { const timer = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(timer); }, []);
  useEffect(() => {
    const add = (choice: WalletChoice) => setWallets(current => current.some(item => item.provider === choice.provider) ? current : [...current, choice]);
    const announce = (event: Event) => {
      const detail = (event as CustomEvent<{ info: { uuid: string; name: string }; provider: BrowserWallet }>).detail;
      if (detail?.provider && detail.info?.uuid) add({ id: detail.info.uuid, name: detail.info.name, provider: detail.provider });
    };
    window.addEventListener('eip6963:announceProvider', announce);
    window.dispatchEvent(new Event('eip6963:requestProvider'));
    const injected = window.ethereum?.providers ?? (window.ethereum ? [window.ethereum] : []);
    injected.forEach((item, index) => add({ id: `injected-${index}`, name: item.isMetaMask ? 'MetaMask' : item.isCoinbaseWallet ? 'Coinbase Wallet' : `Browser wallet${index ? ` ${index + 1}` : ''}`, provider: item }));
    return () => window.removeEventListener('eip6963:announceProvider', announce);
  }, []);
  useEffect(() => { if (!walletId && wallets[0]) setWalletId(wallets[0].id); }, [walletId, wallets]);
  useEffect(() => {
    setAccount(undefined); setWalletChain(undefined); setQuote(undefined);
    if (!provider) return;
    let cancelled = false;
    const accountsChanged = (accounts: string[]) => { revision.current++; setAccount(accounts[0] as Address | undefined); setQuote(undefined); setActionError(''); setStatus(''); };
    const chainChanged = (id: string) => { revision.current++; setWalletChain(Number(BigInt(id))); setQuote(undefined); setVerified(false); setReload(value => value + 1); };
    const disconnect = () => { revision.current++; setAccount(undefined); setQuote(undefined); setStatus('Wallet disconnected. Connect again to continue.'); };
    Promise.all([provider.request({ method: 'eth_accounts' }), provider.request({ method: 'eth_chainId' })]).then(([accounts, chain]) => {
      if (!cancelled) { accountsChanged(accounts); setWalletChain(Number(BigInt(chain))); }
    }).catch(error => { if (!cancelled) setActionError(errorMessage(error)); });
    provider.on('accountsChanged', accountsChanged); provider.on('chainChanged', chainChanged); provider.on('disconnect', disconnect);
    return () => { cancelled = true; provider.removeListener('accountsChanged', accountsChanged); provider.removeListener('chainChanged', chainChanged); provider.removeListener('disconnect', disconnect); };
  }, [provider]);
  useEffect(() => { revision.current++; setQuote(undefined); setFormError(''); }, [buy, input, percent, account, walletChain]);

  useEffect(() => {
    if (!runtime) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout>;
    setVerified(false);
    async function update() {
      setReading(true);
      try {
        const next = await withReadFallback(runtime!, provider, async client => { await verifyChain(runtime!, client); return readSnapshot(runtime!, account, selectedRound, client); });
        if (!cancelled) { setSnapshot(next); setVerified(true); setReadError(''); }
      } catch (error) { if (!cancelled) { setVerified(false); setReadError(errorMessage(error)); } }
      finally { if (!cancelled) { setReading(false); timer = setTimeout(update, 12000); } }
    }
    void update();
    return () => { cancelled = true; clearTimeout(timer); };
  }, [runtime, provider, account, selectedRound, reload]);

  const loadEvents = useCallback(async (older = false) => {
    if (!runtime || !snapshot || eventsLoading) return;
    setEventsLoading(true); setEventError('');
    const deployed = BigInt(runtime.deployment.deploymentBlock);
    const end = older && eventStart ? eventStart - 1n : snapshot.block;
    const start = end - 1999n > deployed ? end - 1999n : deployed;
    try {
      const items = await withReadFallback(runtime, provider, client => readWinners(runtime, start, end, client));
      setWinners(current => {
        // Replace the fetched window so shallow reorgs cannot leave orphaned winners.
        const retained = current.filter(winner => winner.block < start || winner.block > end);
        return [...retained, ...items].sort((a, b) => Number(b.block - a.block) || b.logIndex - a.logIndex);
      });
      setEventStart(current => current === undefined || start < current ? start : current);
      setEventEnd(current => current === undefined || end > current ? end : current);
    } catch (error) { setEventError(errorMessage(error)); }
    finally { setEventsLoading(false); }
  }, [runtime, snapshot, eventsLoading, eventStart, provider]);
  // Wait for the confirmed draw block to reach the snapshot before refreshing logs.
  useEffect(() => {
    const confirmedDraw = snapshot && eventsAfterBlock !== undefined && snapshot.block >= eventsAfterBlock;
    if (snapshot && (eventEnd === undefined || confirmedDraw) && !eventError && !eventsLoading) {
      setEventsAfterBlock(undefined);
      void loadEvents();
    }
  }, [snapshot, eventEnd, eventError, eventsLoading, eventsAfterBlock, loadEvents]);

  const correctChain = !!runtime && walletChain === runtime.chain.id;
  const fresh = !!snapshot && now - snapshot.fetchedAt < 45000;
  const ownSnapshot = snapshot?.account?.toLowerCase() === account?.toLowerCase();
  const ready = !!account && correctChain && verified && fresh && ownSnapshot && !readError && !busy;
  const quoteValid = !!quote && now < quote.expires && quote.account === account && quote.buy === buy && quote.input === input && quote.percent === percent;
  const symbol = snapshot?.symbol || 'TIKT';
  const explorer = runtime?.deployment.network.explorer ?? '';
  const nextSeconds = snapshot ? Math.max(0, Number((snapshot.round + 1n) * snapshot.duration - snapshot.timestamp) - Math.floor((now - snapshot.fetchedAt) / 1000)) : undefined;
  const countdown = nextSeconds === undefined ? '—:—' : `${Math.floor(nextSeconds / 60).toString().padStart(2, '0')}:${(nextSeconds % 60).toString().padStart(2, '0')}`;
  const eligibility = snapshot ? roundAction(snapshot.selected, snapshot.selectedId, snapshot.round, snapshot.block) : undefined;
  const disabledReason = !account ? 'Connect a wallet to trade and manage rounds.' : !correctChain ? `Switch to ${runtime?.chain.name ?? 'the configured network'} to continue.` : !verified || !fresh || !ownSnapshot ? 'Waiting for verified, current chain data. Use Refresh if this persists.' : '';

  async function walletAction(action: 'connect' | 'switch') {
    if (!provider || !runtime || busy) return;
    setBusy(action); setActionError(''); setStatus(action === 'connect' ? 'Choose an account in your wallet.' : 'Confirm the network in your wallet.');
    try {
      if (action === 'connect') {
        const accounts = await provider.request({ method: 'eth_requestAccounts' });
        setAccount(accounts[0] as Address | undefined);
      } else await switchChain(provider, runtime);
      setWalletChain(Number(BigInt(await provider.request({ method: 'eth_chainId' }))));
      setStatus(action === 'connect' ? 'Wallet connected.' : `Switched to ${runtime.chain.name}.`);
    } catch (error) { setActionError(errorMessage(error)); setStatus(''); }
    finally { setBusy(''); }
  }
  async function assertWallet(expected: Address, expectedProvider: BrowserWallet) {
    if (!runtime || activeWallet.current.provider !== expectedProvider || activeWallet.current.account !== expected) throw new Error('Wallet changed. Review the action again.');
    const [chain, accounts] = await Promise.all([expectedProvider.request({ method: 'eth_chainId' }), expectedProvider.request({ method: 'eth_accounts' })]);
    if (Number(BigInt(chain)) !== runtime.chain.id || accounts[0]?.toLowerCase() !== expected.toLowerCase()) throw new Error('Wallet account or network changed. Reconnect and review the action again.');
  }
  function validateAmount() {
    if (!snapshot) throw new Error('Wait for pool data, then try again.');
    const amount = amountUnits(input, buy ? 18 : snapshot.decimals);
    if (amount > (buy ? snapshot.ethBalance : snapshot.tokenBalance)) throw new Error(`Amount exceeds your ${buy ? 'ETH' : symbol} balance.`);
    if (snapshot.ethBalance === 0n || (buy && amount >= snapshot.ethBalance)) throw new Error('Keep some Sepolia ETH in your wallet for gas.');
    return amount;
  }
  async function getQuote(event: FormEvent) {
    event.preventDefault();
    if (!ready || !runtime || !account || !provider || !snapshot) return;
    const version = revision.current;
    setQuote(undefined); setFormError(''); setActionError('');
    try {
      const amount = validateAmount();
      const limit = priceLimit(snapshot.sqrtPrice, buy, percent);
      setBusy('quote'); setStatus('Reading a quote from the pool…');
      await assertWallet(account, provider);
      const result = await withReadFallback(runtime, provider, client => client.simulateContract({
        address: runtime.deployment.network.uniswapV4.quoter, abi: quoterAbi, functionName: 'quoteExactInputSingle',
        args: [{ poolKey: keyFor(runtime), zeroForOne: buy, exactAmount: amount, hookData: identity(account) }], account,
      }));
      if (version !== revision.current) throw new Error('Trade details changed. Get a new quote.');
      if (result.result[0] <= 0n) throw new Error('The pool returned no output. Try a different amount.');
      setQuote({ amount, output: result.result[0], limit, expires: Date.now() + 30000, account, buy, input, percent });
      setStatus('Quote ready. Review the estimate before confirming.');
    } catch (error) { setFormError(errorMessage(error)); document.getElementById('amount')?.focus(); setStatus(''); }
    finally { setBusy(''); }
  }
  async function transact(action: 'approve' | 'swap' | 'seal' | 'draw' | 'claim') {
    if (!ready || !runtime || !provider || !account || !snapshot) return;
    const wallet = provider;
    const signer = account;
    const version = revision.current;
    setBusy(action); setActionError(''); setStatus('Checking the action on Sepolia…'); setTx(undefined);
    let submitted: Hex | undefined;
    try {
      await assertWallet(signer, wallet);
      const request: { address: Address; abi: Abi; functionName: string; args?: readonly unknown[]; value?: bigint; account: Address } = { address: runtime.hook.address, abi: runtime.hook.abi, functionName: action, account: signer };
      if (action === 'swap' || action === 'approve') {
        if (!quote || !quoteValid) throw new Error('Quote expired. Get a new quote before continuing.');
        if (action === 'approve') {
          if (buy) throw new Error('ETH needs no approval.');
          Object.assign(request, { address: runtime.token.address, abi: runtime.token.abi, functionName: 'approve', args: [runtime.deployment.integrations.poolSwapTest, quote.amount] });
        } else Object.assign(request, { address: runtime.deployment.integrations.poolSwapTest, abi: [...routerAbi, ...runtime.hook.abi.filter(item => item.type === 'error')], functionName: 'swap', args: swapParams(keyFor(runtime), signer, quote.amount, quote.buy, quote.limit), value: quote.buy ? quote.amount : 0n });
      } else if (action === 'seal' || action === 'draw') {
        if (action === 'seal' ? eligibility !== 'seal' : !['draw', 'rollover'].includes(eligibility ?? '')) throw new Error('Round is not ready. Refresh its state.');
        request.args = [keyFor(runtime), snapshot.selectedId];
      } else if (snapshot.winnings === 0n) throw new Error('There are no winnings to claim.');
      const simulated = await withReadFallback(runtime, wallet, async client => { await verifyChain(runtime, client); return client.simulateContract(request); });
      if (action === 'swap' && deltaOutput(simulated.result as bigint, buy) <= 0n) throw new Error('Simulation returned no output. Get another quote.');
      if ((action === 'swap' || action === 'approve') && (revision.current !== version || !quote || Date.now() >= quote.expires)) throw new Error('Quote expired or trade changed. Get a new quote.');
      await assertWallet(signer, wallet);
      setStatus(`Confirm ${action === 'swap' ? `${buy ? 'buy' : 'sell'} ${symbol}` : action} in your wallet.`);
      const walletClient = createWalletClient({ account: signer, chain: runtime.chain, transport: custom(wallet) });
      submitted = await walletClient.writeContract({ ...simulated.request, chain: runtime.chain, account: signer });
      setTx(submitted); setStatus('Transaction submitted. Waiting for confirmation…');
      const receipt = await withReadFallback(runtime, wallet, client => client.waitForTransactionReceipt({ hash: submitted!, timeout: 120000 }));
      if (receipt.status !== 'success') throw new Error('Transaction reverted on-chain. Review the explorer details and refresh before retrying.');
      setStatus(`${action === 'approve' ? 'Approval confirmed. Get a fresh quote, then confirm the sell.' : 'Transaction confirmed. Pool data is refreshing.'}`);
      setQuote(undefined); setReload(value => value + 1);
      if (action === 'draw') { setEventsAfterBlock(receipt.blockNumber); setEventError(''); }
    } catch (error) {
      setStatus(''); setActionError(`${errorMessage(error)}${submitted ? ' A transaction was submitted; check its explorer status before retrying.' : ''}`);
    } finally { setBusy(''); }
  }
  function selectRound(event: FormEvent) {
    event.preventDefault(); setRoundError('');
    try {
      if (!/^\d{1,9}$/.test(roundInput)) throw new Error('Enter a UTC round number using digits.');
      const value = BigInt(roundInput);
      if (!snapshot || value > snapshot.round) throw new Error('Choose the current round or an earlier one.');
      setSelectedRound(value);
    } catch (error) { setRoundError(errorMessage(error)); document.getElementById('round-number')?.focus(); }
  }
  const estimatedTicket = quote && snapshot && (buy ? quote.amount >= snapshot.threshold : quote.output * 10000n / (10000n - snapshot.feeBps) >= snapshot.threshold);

  return <>
    <a className="skip-link" href="#main">Skip to content</a>
    <div className="site-shell">
      <header className="header">
        <a className="brand" href="#main" aria-label="Ticket home"><span className="brand-mark"><TicketMark /></span>ticket<span className="brand-dot">.</span></a>
        <nav aria-label="Page"><a href="#rounds">Rounds</a><a href="#how-it-works">How it works</a></nav>
        <div className="wallet-controls">
          <span className="network-badge"><span className="status-dot" />{runtime?.chain.name ?? 'Sepolia'} testnet</span>
          {wallets.length > 1 && <label className="wallet-picker"><span className="sr-only">Browser wallet</span><select value={walletId} disabled={!!busy} onChange={event => setWalletId(event.target.value)}>{wallets.map(wallet => <option key={wallet.id} value={wallet.id}>{wallet.name}</option>)}</select></label>}
          {account ? <span className="account" title={account}>{short(account)}</span> : <button className="button wallet-button" disabled={!!busy || !runtime} onClick={() => provider ? void walletAction('connect') : setActionError('No browser wallet found. Open this page in a wallet browser, or enable a browser wallet extension and reload.')}>Connect wallet <span aria-hidden="true">↗</span></button>}
        </div>
      </header>

      <main id="main">
        <section className="intro">
          <div><p className="eyebrow">A little experiment on Sepolia</p><h1>Every swap.<br /><em>A new possibility.</em></h1></div>
          <div className="intro-note"><span className="mini-ticket"><TicketMark /></span><p>Trade test tokens. Add to the hourly pot.<br /> One qualifying swap, one ticket.</p><a href="#how-it-works">See how the draw works <span aria-hidden="true">↓</span></a></div>
        </section>

        <div className="test-notice"><span className="notice-label">Just a test</span><p>{symbol} and lottery pots have no value. This is a Sepolia experiment, with no promised return.</p></div>
        {configError && <div className="error-banner" role="alert"><strong>Deployment could not be loaded.</strong> {configError} <button onClick={() => location.reload()}>Reload page</button></div>}
        {account && !correctChain && <div className="error-banner"><strong>Wrong network.</strong> Your wallet must use {runtime?.chain.name}. <button disabled={!!busy} onClick={() => void walletAction('switch')}>Switch to {runtime?.chain.name}</button></div>}
        <div className="sync-row"><span><span className={`status-dot ${verified && fresh ? 'live' : ''}`} />{readError ? 'Connection interrupted · actions paused' : verified && fresh ? `Live from block ${snapshot?.block.toLocaleString()}` : 'Connecting to Sepolia…'}</span><button className="text-button" onClick={() => setReload(value => value + 1)} disabled={reading || !!busy || !runtime}>{reading ? 'Refreshing…' : 'Refresh'} <span aria-hidden="true">↻</span></button></div>
        {readError && <div className="error-banner" role="alert">{readError} Last-known values may be shown. Check your connection and select Refresh.</div>}

        <div className="primary-grid">
          <section className="pot-card" aria-labelledby="pot-title">
            <div className="card-top"><h2 id="pot-title">The hourly pot</h2><span className="pill">{snapshot ? `Round ${snapshot.round}` : 'Loading round'}</span></div>
            <div className="pot-amount"><span>{snapshot ? number(snapshot.current.pot, 18, 8) : '—'}</span> <span className="unit">ETH</span></div>
            <p className="pot-caption">A shared pot, built one swap at a time.</p>
            <div className="ticket-art" aria-hidden="true"><span className="ticket-art-label">Sepolia hourly draw</span><TicketMark /><span className="ticket-art-code">TIKT / 001</span></div>
            <div className="round-metrics"><div><span className="metric-label">Tickets this hour</span><strong>{snapshot ? snapshot.current.ticketCount.toLocaleString() : '—'}</strong></div><div><span className="metric-label">Your tickets</span><strong>{account && ownSnapshot ? snapshot?.owned.toLocaleString() ?? '—' : '—'}</strong></div><div><span className="metric-label">Hour ends in</span><strong className="countdown">{countdown}</strong></div></div>
            <div className="pot-footer"><span>{snapshot ? `${roundDate(snapshot.round)} UTC` : 'UTC hourly rounds'}</span><span>{nextSeconds === 0 ? 'Waiting for the next block' : 'Drawn after the hour ends'}</span></div>
          </section>

          <section className="trade-card" aria-labelledby="trade-title">
            <div className="card-top"><h2 id="trade-title">Make a swap</h2><span className="subtle">ETH / {symbol}</span></div>
            <div className="segmented" role="group" aria-label="Trade direction"><button aria-pressed={buy} disabled={!!busy} onClick={() => { setBuy(true); setInput('0.001'); }}>Buy {symbol}</button><button aria-pressed={!buy} disabled={!!busy} onClick={() => { setBuy(false); setInput('100'); }}>Sell {symbol}</button></div>
            <form onSubmit={getQuote} noValidate>
              <label className="amount-box" htmlFor="amount"><span className="input-label">You pay</span><span className="amount-row"><input id="amount" name="amount" inputMode="decimal" autoComplete="off" value={input} disabled={!!busy} onChange={event => setInput(event.target.value)} aria-invalid={!!formError} aria-describedby="amount-help trade-error" /><span className="currency"><span className="currency-symbol" aria-hidden="true">{buy ? 'Ξ' : 'T'}</span>{buy ? 'ETH' : symbol}</span></span><span id="amount-help" className="balance">Balance: {account && snapshot && ownSnapshot ? `${number(buy ? snapshot.ethBalance : snapshot.tokenBalance, buy ? 18 : snapshot.decimals)} ${buy ? 'ETH' : symbol}` : 'connect wallet'}</span></label>
              <div className="receive-box"><span className="input-label">Estimated receive</span><div className="amount-row"><strong>{quote ? number(quote.output, buy ? snapshot?.decimals : 18) : '—'}</strong><span>{buy ? symbol : 'ETH'}</span></div><span className="balance">{quote ? quoteValid ? `Quote expires in ${Math.max(0, Math.ceil((quote.expires - now) / 1000))}s` : 'Quote expired. Get a fresh quote.' : 'Get a quote to see the pool estimate'}</span></div>
              <div className="limit-row"><label htmlFor="price-limit">Pool price movement limit</label><span><input id="price-limit" name="priceLimit" aria-describedby="router-note" inputMode="decimal" value={percent} disabled={!!busy} onChange={event => setPercent(event.target.value)} /><span>%</span></span></div>
              <p id="trade-error" className="field-error" role={formError ? 'alert' : undefined}>{formError}</p>
              <dl className="trade-details"><div><dt>Lottery fee</dt><dd>{snapshot ? `${Number(snapshot.feeBps) / 100}%` : '0.5%'} of ETH leg</dd></div><div><dt>Pool fee</dt><dd>{runtime ? runtime.deployment.pool.fee / 10000 : '0.3'}%</dd></div><div><dt>Ticket estimate</dt><dd>{quote ? estimatedTicket ? '1 ticket' : 'Below threshold' : '—'}</dd></div></dl>
              <p id="router-note" className="router-note">The test router enforces a pool-price bound, with no minimum received or deadline. Quotes are estimates; a limit hit reverts the swap.</p>
              <button type="submit" className="button primary" disabled={!ready}>{busy === 'quote' ? 'Getting quote…' : quoteValid ? 'Refresh quote' : 'Get quote'}<span aria-hidden="true">↗</span></button>
            </form>
            {quote && <div className="quote-actions"><p>{buy ? `Spend ${number(quote.amount)} ETH to buy ${symbol}.` : `Sell ${number(quote.amount, snapshot?.decimals)} ${symbol} for ETH.`} Your wallet receives the output and is encoded as the ticket holder.</p>{!buy && snapshot && snapshot.allowance < quote.amount ? <><p>Step 1 of 2: approve exactly {number(quote.amount, snapshot.decimals)} {symbol} for PoolSwapTest. After confirmation, get a new quote.</p><button className="button" disabled={!ready || !quoteValid} onClick={() => void transact('approve')}>Approve {symbol}</button></> : <button className="button" disabled={!ready || !quoteValid} onClick={() => void transact('swap')}>Confirm {buy ? 'buy' : 'sell'} {symbol}</button>}</div>}
            {disabledReason && <p className="action-hint">{disabledReason}</p>}
            <p className="spot-price">{snapshot ? `1 ETH ≈ ${new Intl.NumberFormat('en', { maximumFractionDigits: 2 }).format((Number(snapshot.sqrtPrice) / 2 ** 96) ** 2 * 10 ** (18 - snapshot.decimals))} ${symbol}` : 'Pool price loading…'}<span>Uniswap v4 · StateView</span></p>
          </section>
        </div>

        <div className="transaction-region" aria-live="polite" role="status">{status && <p>{busy && <span className="busy-dot" aria-hidden="true" />} {status}</p>}{tx && <p><External href={`${explorer}/tx/${tx}`}>View transaction {short(tx)}</External></p>}</div>
        {actionError && <div className="error-banner" role="alert">{actionError}<button onClick={() => setActionError('')}>Dismiss message</button></div>}

        <section id="rounds" className="rounds-section" aria-labelledby="rounds-title">
          <div className="section-heading"><div><p className="eyebrow">Keep the experiment moving</p><h2 id="rounds-title">Close an hour. Open a possibility.</h2></div><p>Anyone can seal and draw an ended round.<br /> No keeper, no admin, just the contract.</p></div>
          <div className="secondary-grid">
            <section className="panel round-panel" aria-labelledby="manage-title">
              <div className="card-top"><h3 id="manage-title">Manage a round</h3><span className="pill neutral">{snapshot ? ['Open', 'Sealed', 'Drawn', 'Rolled over'][snapshot.selected.status] : 'Loading'}</span></div>
              <form className="round-picker" onSubmit={selectRound}><label htmlFor="round-number">UTC round number</label><div><input id="round-number" inputMode="numeric" value={roundInput} placeholder={snapshot?.selectedId.toString()} onChange={event => setRoundInput(event.target.value)} aria-invalid={!!roundError} aria-describedby="round-error" disabled={!!busy} /><button disabled={!snapshot || !!busy}>Load round</button><button type="button" disabled={!!busy} onClick={() => { setSelectedRound(undefined); setRoundInput(''); setRoundError(''); }}>Previous hour</button></div><p id="round-error" className="field-error">{roundError}</p></form>
              <p className="round-time">{snapshot ? `Round ${snapshot.selectedId} · ${roundDate(snapshot.selectedId)} UTC` : 'Loading round…'}</p>
              <dl className="trade-details"><div><dt>Pot</dt><dd>{snapshot ? number(snapshot.selected.pot, 18, 8) : '—'} ETH</dd></div><div><dt>Tickets</dt><dd>{snapshot?.selected.ticketCount.toLocaleString() ?? '—'}</dd></div>{snapshot && snapshot.selected.status === 1 && <div><dt>Target block</dt><dd>{snapshot.selected.targetBlock.toString()}</dd></div>}</dl>
              <p className="round-guidance">{eligibility === 'seal' ? 'This hour has ended. Seal it to select the next block as its randomness source.' : eligibility === 'wait' ? `Wait until block ${(snapshot!.selected.targetBlock + 1n).toString()} to draw.` : eligibility === 'draw' ? `Ready to draw. The last valid draw block is ${(snapshot!.selected.targetBlock + 256n).toString()}.` : eligibility === 'rollover' ? 'This round is empty or its draw window expired. Calling draw rolls its pot into the current hour.' : eligibility === 'finished' ? snapshot?.selected.status === 3 ? `Pot rolled into round ${snapshot.selected.rolledInto}.` : `Winner: ${snapshot?.selected.winner}` : 'The current round remains open until the hour ends.'}</p>
              <div className="button-row"><button className="button" disabled={!ready || eligibility !== 'seal'} onClick={() => void transact('seal')}>Seal round</button><button className="button" disabled={!ready || !['draw', 'rollover'].includes(eligibility ?? '')} onClick={() => void transact('draw')}>{eligibility === 'rollover' ? 'Roll over pot' : 'Draw winner'}</button></div>
            </section>
            <section className="panel claim-panel" aria-labelledby="claim-title"><span className="claim-symbol" aria-hidden="true">✳</span><h3 id="claim-title">A winning ticket?</h3><p>Winnings stay in the contract until you claim them to your connected wallet.</p><div className="claim-amount">{account && ownSnapshot && snapshot ? number(snapshot.winnings, 18, 8) : '—'} <span>ETH</span></div><p className="subtle">{account ? snapshot?.winnings ? 'Available to claim' : 'No winnings to claim yet' : 'Connect to check your winnings'}</p><button className="button" disabled={!ready || !snapshot?.winnings} onClick={() => void transact('claim')}>Claim winnings <span aria-hidden="true">↗</span></button></section>
          </div>
        </section>

        <section className="history-section" aria-labelledby="history-title"><div className="section-heading"><div><p className="eyebrow">From the chain</p><h2 id="history-title">Past winners</h2></div><button className="text-button" disabled={!snapshot || eventsLoading} onClick={() => void loadEvents()}>{eventsLoading ? 'Loading events…' : 'Refresh winners'} <span aria-hidden="true">↻</span></button></div>
          {eventError && <p className="error-banner" role="alert">Winner history could not load: {eventError} Select Refresh winners to retry.</p>}
          {winners.length ? <div className="winner-list">{winners.map(winner => <article className="winner-row" key={`${winner.hash}-${winner.logIndex}`}><span className="winner-icon" aria-hidden="true"><TicketMark /></span><div><strong>Round {winner.round.toString()}</strong><span>{roundDate(winner.round)} UTC</span></div><External href={`${explorer}/address/${winner.winner}`} title={winner.winner}>{short(winner.winner)}</External><strong>{number(winner.pot, 18, 8)} ETH</strong><External href={`${explorer}/tx/${winner.hash}`}>View draw</External></article>)}</div> : <div className="empty-history"><span aria-hidden="true"><TicketMark /></span><div><h3>{eventsLoading ? 'Looking for completed draws…' : 'No winners in the loaded blocks'}</h3><p>Winners appear here after a round is drawn. Load older blocks to explore earlier draws.</p></div></div>}
          <div className="history-footer"><p>{eventStart !== undefined && eventEnd !== undefined ? `Drawn events · blocks ${eventStart.toLocaleString()}–${eventEnd.toLocaleString()}. Loaded windows may have gaps after a long pause.` : 'History loads in pages of up to 2,000 blocks.'}</p><button disabled={eventsLoading || eventStart === undefined || !runtime || eventStart <= BigInt(runtime.deployment.deploymentBlock)} onClick={() => void loadEvents(true)}>Load older blocks</button></div>
        </section>

        <section id="how-it-works" className="how-section" aria-labelledby="how-title"><p className="eyebrow">The small print, made readable</p><h2 id="how-title">One hour. One shared pot.</h2><div className="how-grid"><article><span>01 / Swap</span><h3>Trade to take part</h3><p>A swap with an ETH leg of at least {snapshot ? number(snapshot.threshold) : '0.001'} ETH earns one ticket. Each swap adds {snapshot ? Number(snapshot.feeBps) / 100 : '0.5'}% of its ETH leg to the pot.</p></article><article><span>02 / Draw</span><h3>Let the hour finish</h3><p>Seal an ended round, then draw after its target block. The next 256 blocks are the draw window. Empty or expired rounds roll over.</p></article><article><span>03 / Claim</span><h3>Bring it to your wallet</h3><p>The selected ticket holder can claim the whole pot. Tickets reset each UTC hour. No purchase guarantees a winning ticket.</p></article></div><details><summary>Understand the experiment</summary><div className="details-copy"><p>Ticket identity comes from hookData. This page encodes your connected wallet, but the contract does not authenticate identities supplied by other callers. Tickets are round entries, separate from your {symbol} token balance.</p><p>A future blockhash selects the winner. A proposer can bias this randomness by withholding a block. There is no VRF, external oracle or automated keeper. These mechanics are suitable only for this Sepolia test toy.</p><p>PoolSwapTest is a test router. Token sells approve this router directly for the entered amount. ETH buys need no approval. Its price bound limits spot-price movement; it does not guarantee a quoted output or impose a transaction deadline. The 0.5% lottery fee and pool fee are reflected in the quote. Gas is separate.</p></div></details></section>
      </main>
      <footer><div className="footer-top"><a className="brand" href="#main">ticket.</a><p>An on-chain experiment.<br /> Built for curiosity, not returns.</p>{runtime && <div className="contract-links">{runtime.deployment.contracts.map(contract => <External key={contract.name} href={`${explorer}/address/${contract.address}`} title={contract.address}>{contract.name}</External>)}<External href={`${explorer}/address/${runtime.deployment.integrations.poolSwapTest}`}>PoolSwapTest</External><External href={`${explorer}/address/${runtime.deployment.network.uniswapV4.stateView}`}>StateView</External></div>}</div><details className="deployment-details"><summary>Deployment details & public RPCs</summary>{runtime && <><dl><dt>Connected wallet</dt><dd>{account ?? 'Not connected'}</dd><dt>Pool ID</dt><dd>{poolId(keyFor(runtime))}</dd><dt>Source commit</dt><dd>{runtime.deployment.sourceCommit}</dd><dt>Attestation hash</dt><dd>{runtime.deployment.attestationHash}</dd></dl><ul>{runtime.deployment.network.rpcUrls.map(url => <li key={url}>{url}</li>)}</ul><p>Contract ABIs are verified against this export’s deployment manifest. Chain, contract code and PoolManager bindings are checked before actions are enabled.</p><a href="./imd-deployment.json">View deployment manifest</a><p><External href={runtime.deployment.network.faucets[0]}>Get Sepolia test ETH</External></p></>}</details><div className="footer-bottom"><span>Sepolia only · Test tokens have no value</span><span>Uniswap v4 / hourly lottery</span></div></footer>
    </div>
  </>;
}
