# Ticket frontend

A single-page React + TypeScript application for the deployed Sepolia Ticket / SwapLotteryHook pool. Vite exports plain files to repository-root `dist/`. No server, private credentials, remote fonts, WalletConnect project ID, or contract redeployment is required.

TIKT and lottery pots have no value. Nothing here promises a return. A future blockhash selects the winner and a proposer can bias it by withholding a block. There is no VRF, external oracle, or keeper. The hook accepts an **unauthenticated** address in `hookData`; this page encodes the connected wallet, but other callers can choose another identity.

## Install, develop, export

Use Node 24. The lockfile pins all dependencies. From this directory:

```sh
npm ci
npm run dev
npm run typecheck
npm run build
npm run verify:export
npm run preview
```

The worker installed dependencies with `npm install --cache ../test/scratch/npm-cache`; that same cache option can be used with `npm ci` for a writable, excluded cache. Neither that cache nor `node_modules` is delivered. No vendored registry or dependency archives are needed. `web/.gitignore` is the only ignore-file path used; its explicit path budget is one file. Patterns exclude generated dependencies/caches at every nesting level within `web/`.

`build` checks TypeScript, verifies/copies pinned ABIs, builds with Vite `base: './'`, then **rebuilds** `dist/imd-deployment.json` from the final bytes. It removes the previous export. Serve `dist/` over HTTP, at a root or directory subpath. The app uses page anchors and relative assets, with no server rewrites. Opening `index.html` via `file://` is unsupported because deployment/ABI JSON uses fetch.

The deployed commit must exist in Git to rebuild: `6804778c746e11f610433bf194aec95f947d00ad`. The production site itself does not require Git, Node, the handoff source files, or a build service.

## Deployment configuration and integrity

The browser reads **only `dist/imd-deployment.json`** for addresses, chain, RPC URLs, pool parameters, external integrations, and ABI paths. It fetches the referenced implementation-derived ABIs and checks each canonical Keccak hash before enabling reads/actions. It does not import a second deployment map.

Build inputs in `web/deployment/`:

- `handoff.json`: unchanged copy of the provided deployed handoff, including the exact contract set, source commit and attestation.
- `network.json`: unchanged supplied network and wallet-add-chain parameters.
- `integration.json`: the assignment's explicitly required PoolSwapTest address, which the supplied network object does not contain.

`scripts/deployment.mjs` reads `docs/abi/<Contract>.json` with `git show <sourceCommit>:...`; current working-tree ABIs cannot silently replace the pinned exports. It hashes recursively key-sorted JSON with Keccak-256, preserves array order, compares against the handoff, and copies the original ABI bytes. Both hashes match:

| Contract | Canonical Keccak-256 |
| --- | --- |
| Ticket | `f36d2fe28b62f817a4fba0b78bb501b41895eada3982280273c063ad8183f577` |
| SwapLotteryHook | `e5ad344e00507aa451f64dea83ae92104d436dae9e0fe4c07b511feef66ad459` |

The manifest copies the network object without changing any field/value. Additional `pool`, `deploymentBlock`, `walletAddChain` and `integrations` fields make it the complete runtime configuration. Every other file is listed with its SHA-256; the manifest excludes itself. The verifier checks exact handoff values, network equality, original ABI bytes, inventory, sizes and hashes. Re-run the build after any export change; never edit the output without regenerating the manifest.

This is binding to the supplied attestation, not an independent signature-verification service. The app verifies live chain ID, nonempty code for both deployed contracts and the four used Uniswap contracts, and the hook/router/StateView/quoter PoolManager bindings. It does not attest deployed runtime bytecode against creation bytecode hashes.

## Wallets, quotes and actions

EIP-6963 browser wallets and legacy EIP-1193 injection are supported, with a chooser for multiple wallets. No private key or seed is used. An unavailable wallet has a recovery message. Unknown-chain error `4902` triggers the exact supplied `wallet_addEthereumChain` parameters followed by another switch. Rejections, account/chain changes and disconnects are handled. RPC reads fall back across the three configured public endpoints, then to a connected wallet on the correct chain.

The assignment specifically requires **PoolSwapTest**, rather than the generic reference's Universal Router route. That specific router is the sole `integrations.poolSwapTest` entry; the unchanged `network.uniswapV4` block supplies StateView, quoter and PoolManager. Universal Router and Permit2 remain in that block as supplied but are not used for this router's swaps. Token sells approve PoolSwapTest directly for exactly the entered amount. ETH buys require no approval. Approve and swap are separate wallet confirmations; after approval the visitor obtains a fresh quote.

Quotes call the supplied quoter's `quoteExactInputSingle` through `simulateContract`, with the connected wallet encoded in `hookData`. Quotes expire after 30 seconds and are invalidated on account, network or form changes. Decimal parsing uses the token's on-chain decimals and rejects excess precision, negatives, zero and exponent notation. Available balances are checked and ETH must remain for gas. There is no fixed gas-limit assumption; the wallet handles gas estimation.

PoolSwapTest's `swap` takes a `sqrtPriceLimitX96`, **not a minimum output or a deadline**. The UI therefore labels the setting “Pool price movement limit” (0.1%–5%, default 1%). Integer square-root arithmetic conservatively bounds token1/token0 spot-price movement from the displayed snapshot. The hook's `PartialFill` check reverts if the specified amount cannot fill within this bound. This is not a guaranteed quoted output or conventional amount-out slippage guarantee. The quote includes pool/hook effects; gas is separate. A pending wallet transaction has no on-chain expiry.

Every approval, swap, seal, draw and claim is simulated before signing. Account, chain, code and manager bindings are rechecked. Receipt success/revert, rejection, RPC failures and explorer links are shown. A submitted transaction whose receipt cannot be obtained remains explicitly identified as submitted.

## Reads and lottery lifecycle

- Snapshot reads use one block number: round state, pot, tickets, wallet tickets/winnings/balances/allowance, fee/threshold constants, and StateView pool price. They refresh every 12 seconds; action prerequisites expire after 45 seconds without a fresh snapshot. Countdown derives from chain timestamp plus elapsed browser time.
- A round is a UTC hour. The default management selection is the previous hour; any current/past round number can be loaded.
- Seal is available only for an ended open round. Draw is available strictly after `targetBlock`, through `targetBlock + 256` inclusive. Empty or expired rounds display “Roll over pot,” calling the same `draw` function. Finished rounds cannot be processed twice.
- `winnings(account)` controls claim availability. `claim()` pays that wallet.
- History uses actual `Drawn` logs filtered by pool ID. It loads at most 2,000 blocks per page, splits ranges when RPC providers reject large ranges, refreshes on request/after a draw, and can page back to deployment. Replacing a refreshed window removes orphaned events in that window. The page explicitly states coverage; long pauses between refreshed windows may leave gaps. This is not a finalized chain indexer.

## Validation

```sh
npx playwright install chromium
npm test
npm run check:live
npm run verify:export
```

On this worker Chromium was already installed; the actual test command was:

```sh
PLAYWRIGHT_CHROMIUM_EXECUTABLE=/home/imd2/.cache/ms-playwright/chromium-1246/chrome-linux64/chrome npm test
```

`tests/browser.mjs` owns and closes its HTTP server and headless browser. It serves the **production export** at `/preview/`, mocks all RPC/signing, exercises real page controls and decodes captured transaction payloads. It writes evidence under `docs/evidence/`. `check:live` only performs read calls and quote simulations; it never broadcasts. Full commands, coverage and limitations are in [validation.md](../docs/validation.md). Design tokens and responsive behavior are in [DESIGN.md](../docs/DESIGN.md).

Real wallet extension prompts, real funded swaps/approvals/draws/claims, physical devices, screen readers, native browser zoom, transaction replacement, and publication checks were not exercised. IPFS pinning, DNS/site naming and deployed URLs are publisher work, not this worker's completion prerequisites.

The root `DESIGN.md` request conflicts with the assignment's higher-priority path rules. Its complete content is delivered at `docs/DESIGN.md`; root configuration and deployed sources are unchanged.

## Interface sources

The hook and token interfaces come from the pinned source. External fragments in `src/protocol.ts` were checked against the repository's `lib/v4-core/src/test/PoolSwapTest.sol`, Uniswap's [StateView](https://github.com/Uniswap/v4-periphery/blob/main/src/lens/StateView.sol), [IV4Quoter](https://github.com/Uniswap/v4-periphery/blob/main/src/interfaces/IV4Quoter.sol), and [published deployments](https://developers.uniswap.org/docs/protocols/v4/deployments). Addresses are taken from assignment inputs, not those mutable pages. See [attribution](../docs/ATTRIBUTION.md) for the pinned design references.
