# Frontend validation record

## Outcome and scope

The permitted frontend implementation and local checks are complete. Source and lockfile are under `web/`; the complete static export and deployment manifest are under `dist/`; documentation and evidence are under `docs/`. No contract, library, root build configuration, root ignore file, or CI file was changed. No publication, contract deployment, or real wallet transaction was performed.

**Repository commit is blocked by the worker filesystem.** `git add -- web dist docs` failed with `Unable to create …/.git/index.lock: Read-only file system`. The deliverable remains as files for the contributor network to collect; no repository commit is claimed. No permission bypass was attempted.

The root `DESIGN.md` criterion conflicts with the explicit higher-priority write scope. The full design record is at `docs/DESIGN.md`, and this exception is also recorded in `web/README.md`. The only ignore-file path used is the explicitly allowed `web/.gitignore` (one-file path budget).

## Commands and observed results

All frontend commands below ran from `web/` using Node 24.21.0 and npm 11.19.0.

| Check | Observed result |
| --- | --- |
| Dependency installation with an excluded scratch npm cache | Passed; npm reported zero vulnerabilities at installation |
| `npm run build` | Passed; includes `tsc --noEmit`, pinned ABI extraction/hash checks, Vite static build and final manifest generation |
| `PLAYWRIGHT_CHROMIUM_EXECUTABLE=/home/imd2/.cache/ms-playwright/chromium-1246/chrome-linux64/chrome npm test` | Passed: 7 unit tests and 16 browser interaction scenarios |
| `npm run check:live` | All 3 supplied RPCs returned the correct chain, nonempty configured contract code, correct manager bindings, live hook/pool state and a read-only buy quote |
| `npm run verify:export` | Passed: exact handoff/network agreement, pinned ABI bytes and canonical hashes, 6 exported assets, 599,949 asset bytes, no missing/extra inventory entries |
| `cmp` on both supplied JSON files and their `web/deployment/` copies | Passed; originals preserved byte for byte |
| `git diff -- src lib foundry.toml remappings.txt .github` | Empty |
| `git diff --check` | Passed for tracked changes; new-file scope/content checks are recorded in `evidence/submission.json` |
| `git ls-files --stage` checked for mode `160000` | No submodules |

Vite reported a non-blocking large-chunk warning: the main JavaScript file is about 541 kB uncompressed / 165 kB gzip. The whole static export is about 603 kB including configuration, well below the asset and HTTP-response budgets. Source maps, dependency archives, package caches and `node_modules` are absent from the submission file list. Actual submitted bytes and conservative bundle-budget headroom are recorded in `evidence/submission.json`; an exact final commit bundle cannot be produced in the protected repository.

The first browser run needed the worker's already-installed Chromium executable instead of Playwright's different default revision. Two harness issues were repaired: matching normalized RPC URLs with a trailing slash and paging history to the actual deployment boundary. These were test-scaffolding issues. The final run above passed against the final production bytes.

## Interaction evidence

`web/tests/browser.mjs` runs the real production page under `/preview/` with all public RPC requests intercepted and an injected EIP-1193 wallet. It starts and closes its own preview/browser. Tests decode captured calldata rather than merely counting clicks. `docs/evidence/interactions.json` lists all 16 passed scenarios, including:

- Disconnected live reads and disabled transaction controls; wallet rejection; wrong chain and exact switch/add/switch sequence.
- Invalid amount and focused error; configured-quoter estimate with encoded wallet identity; quote expiry; account changes and disconnect invalidation.
- Buy through the required PoolSwapTest with native value and exact negative input; sell with exact direct router approval, a fresh quote, zero ETH value and opposite direction.
- Simulation revert blocking the signing request; rejected signature; missing-code and RPC failures disabling actions, with recovery on Refresh.
- Seal, target-block wait, valid draw, winnings claim, expired-window rollover, historical round selection and older `Drawn` event pages.
- Responsive layouts, accessibility audit, contrast samples, keyboard focus, reduced motion, text enlargement and static-resource/console checks.

Unit coverage includes canonical implementation ABI hashes; decimal/amount bounds; target-block, `+1`, `+256`, `+257`, empty and completed round cases; integer price bounds; router ABI encoding and signed deltas; unknown-chain and rejected-chain behavior.

The current/past pots, tickets, claims and winner addresses shown in `mocked-*.webp` are **fixtures**, not chain observations. `live-*.webp` and `live-rpc.json` use public Sepolia reads. The live snapshot observed an empty current/previous hour; this is not substituted with fixture data in the shipped application.

## Rendered review

The supplied browser tool inspected the actual export on a bounded local HTTP preview. An unrelated server already occupied port 4173; the review used the separately verified Ticket preview on 4187. That preview process terminated after its bounded lifetime. Automated interaction checks independently served the export at `/preview/` and closed that server after each run.

Visual inspection covered desktop 1440 × 1000 and narrow 320 × 900 live states, plus the saved 390px connected fixture and keyboard focus image. Automated browser checks covered 1440, 768, 390 and 320px widths. No horizontal document overflow was found at those widths. The no-wallet control was exercised in the supplied browser and showed actionable extension/wallet-browser guidance. A final bounded Playwright capture also served the final export at `/preview/` after the event-refresh repair. The final live browser recorded zero console errors/warnings and successfully loaded the HTML, bundled JavaScript/CSS, deployment JSON and both ABIs.

Evidence:

- `evidence/live-desktop.webp`, `evidence/live-320.webp`: public-chain, disconnected export.
- `evidence/mocked-1440.webp`, `evidence/mocked-390.webp`, `evidence/mocked-320.webp`: connected data, winners and enabled actions using fixtures.
- `evidence/keyboard-focus.webp`: visible focus ring around the Buy button.
- `evidence/accessibility.json`: four axe scans, dimensions, computed input/focus behavior, measured contrast samples, reduced-motion and text enlargement result.
- `evidence/live-console.txt`: supplied browser's console result.
- `evidence/live-rpc.json`: endpoint-by-endpoint chain/code/manager/view/quote evidence; `broadcastTransactions: false`.

## Better Interface consolidated review

The pinned workflow, all six core domains and documentation method were read and applied. See `ATTRIBUTION.md` for the original authors, commits and distinct licenses.

| Domain | Coverage | Evidence and limitations |
| --- | --- | --- |
| Accessibility | Checked | Native controls/landmarks, one h1, labels, pressed/disabled semantics, stable status region, alert/error descriptions, skip link and focus styles; axe WCAG 2 A/AA, 2.1 AA and 2.2 AA rules found no violations at all four widths. Keyboard focus was rendered and inspected. A full screen-reader session and physical touch-device testing were not performed. |
| Layout | Checked | Shared edges and spacing, desktop grids and stacked mobile order, 320px reflow, wrapping controls, actual document-width checks, rendered desktop/mobile review. Root text enlarged to 200% without overflow at 1440px. Native browser 200% zoom and an RTL/localization variant were not tested; the delivered interface is English only. |
| Writing | Checked | Action-specific verbs, token units, precise lottery/timing language, visible test-toy notice, router limitations, unauthenticated identity/randomness details, recoverable errors and honest history coverage. Mobile line-break spacing was corrected. |
| Typography | Checked | System serif/sans stack, restrained heading hierarchy, tabular values, line-height/measure, long-value wrapping, input size ≥16px on mobile. Specific installed font-file identity and other operating-system fallbacks were not established. |
| Colors | Checked | Semantic tokens, text plus color state cues, rendered contrast calculations. The six measured normal-text pairs all exceeded 4.5:1; lowest sample 4.91:1. This is a light-only design; no dark-theme audit applies. Forced-color rules were reviewed in source but not visually audited. |
| UI details | Checked | Selected, disabled, error, empty, loading, quote and transaction states exercised. Button press/background transitions are 120ms and disabled under reduced-motion emulation. No dialog, image loading, autoplay or page entrance animation exists; slow-motion replay is not applicable to those absent features. |

### Findings, fixes and rechecks

| Severity | Source | Finding and fix | Recheck |
| --- | --- | --- | --- |
| Medium | `web/src/App.tsx:256`, `web/src/styles.css:218` | At narrow width the hidden intro line break joined “pot.One”. Added explicit text whitespace so removing the visual line break preserves sentence separation. Related explicit line-break prose was also corrected. | Final 320px live DOM reads “pot. One”; final screenshots and overflow/axe checks passed. |
| Medium | `web/src/App.tsx:8` | Source review found that nonzero dust below the displayed precision could be formatted as `0.0`. Added a “less than the display unit” representation. | Source reviewed; final TypeScript/build and whole interaction suite passed. No real dust swap was broadcast. |
| Medium | `web/src/App.tsx:125` | Source review found that post-draw logs could be queried using the pre-receipt snapshot. Wait for a snapshot at or beyond the receipt block before refreshing events. | Browser fixture advances the receipt block beyond the old snapshot and asserts that displayed event coverage reaches it; final browser suite passed. |

No unresolved rendered defect was observed in the checked states. Automated audits are not a claim of complete accessibility compliance.

## Contract/configuration review and limits

The explicit PoolSwapTest requirement takes precedence over the background Universal Router/Permit2 recipe. The network block is unchanged. StateView/quoter/PoolManager come from that block; the specifically assigned test router is stored once in the manifest's integration field and is the spender for sell approval. The UI correctly avoids advertising minimum-output protection or a deadline that this router does not implement.

Deployed source and floor-test inputs were read, not modified. No Foundry suite was rerun for this frontend-only assignment. Callback/admin methods are not presented as user actions; the primary hook actions are seal, draw and claim. ERC-20 approvals are exposed only as part of the required sell flow.

Unperformed live-chain behavior: actual extension signature dialogs, approvals, funded buys/sells, seals, draws, claims, receipt replacement/reorg behavior, and public-RPC outage recovery with a real wallet. Mocked tests establish page behavior under the modeled responses, not execution on a live chain. No independent contract audit or randomness guarantee is claimed. WalletConnect/native mobile wallets, screen readers and physical devices were not tested.

IPFS publication, fixed/named CID fetching, naming and the control plane's later RPC/asset checks remain outside this worker's scope. Their results are not claimed as frontend validation. The remaining delivery limitation is the read-only Git metadata; all permitted implementation/export/evidence files are present for collection.
