# Ticket (TIKT) + SwapLotteryHook

A Sepolia `univ4_hook` launch: a fixed-supply ERC-20 and a Uniswap v4 hook that runs an hourly swap
lottery on the token's native-ETH pool.

**Ticket is a Sepolia test toy.** The token and every lottery pot have no value, and nothing here
promises a return.

## Contents

| Path | What |
| --- | --- |
| `src/Ticket.sol` | TIKT: 1,000,000,000 × 10^18, minted once to the deployer, no constructor arguments, no owner, no mint. |
| `src/SwapLotteryHook.sol` | The hook. Constructor takes exactly one argument, the PoolManager. |
| `src/HookFlags.sol` | Permission-bit constants and address helpers. |
| `src/HookMiner.sol` | CREATE2 salt mining for the required address bits. |
| `src/LaunchParams.sol` | Pool key, manifest price and seed parameters in one place. |
| `script/Deploy.s.sol` | Rehearsal deployment (token + hook at a mined salt). The factory does the real launch. |
| `test/` | Foundry suite (see below). `test/mocks/MockERC20.sol` is used for the non-ETH pool case. |
| `docs/abi/Ticket.json`, `docs/abi/SwapLotteryHook.json` | ABI exports (`forge inspect <Contract> abi --json`). |
| `lib/` | Vendored dependencies as plain files; provenance in `lib/VENDORED.md`. |

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"` (the PoolManager needs transient
storage) and `bytecode_hash = "none"`. No `ffi`, no filesystem permissions, no environment variables in
tests; the suite passes in any order and in parallel.

## Hook mechanics

All state is keyed by `PoolId`. A pool whose `currency0` is not native ETH gets zero deltas and no other
effect (its swaps are untouched, `seal` reverts with `NotEthPool`).

| Parameter | Value | Where |
| --- | --- | --- |
| Fee on the ETH leg | 50 bps (`FEE_BPS / BPS_DENOMINATOR`) | source constant |
| Ticket threshold | 0.001 ETH (`TICKET_THRESHOLD`) | source constant |
| Round | `block.timestamp / 3600` (UTC hours, `ROUND_DURATION`) | source constant |
| Blockhash window | 256 blocks after `targetBlock` (`BLOCKHASH_WINDOW`) | source constant |
| Permissions | beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta = `0x00CC` | `getHookPermissions`, validated in the constructor |

There is no owner, setter, pause, upgrade, sweep, proxy, delegatecall or selfdestruct.

### Fee and settlement (ETH-leg mechanics)

A buy is `zeroForOne` (ETH in); a sell is `oneForZero` (ETH out). The swapper's specified amount is
always honoured exactly.

| Mode | ETH is | Fee base | Charged as |
| --- | --- | --- | --- |
| Exact-in buy | specified | `\|amountSpecified\|` | positive **specified** `BeforeSwapDelta` in `beforeSwap`; the pool swaps `input − fee` |
| Exact-out sell | specified | `\|amountSpecified\|` | positive **specified** `BeforeSwapDelta` in `beforeSwap`; the pool pays `output + fee` |
| Exact-out buy | unspecified | ETH the pool moved | positive **unspecified** delta returned by `afterSwap` |
| Exact-in sell | unspecified | ETH the pool moved | positive **unspecified** delta returned by `afterSwap` |

`fee = floor(base × 50 / 10 000)`; a fee that rounds to zero is zero, so dust never reverts. A partial
fill (the price limit was reached before the specified amount was filled) reverts with `PartialFill`.

The hook resolves its positive delta by minting itself ERC-6909 claims on native ETH (`poolManager.mint`)
inside `afterSwap`. It never calls `take` or moves ETH inside a swap callback, so the first buy into the
ETH-less pool the factory opens works. `claim()` pays `msg.sender` its winnings: the balance is zeroed
first, then the hook unlocks the PoolManager, burns claims and takes ETH in its own `unlockCallback`.

**Invariant:** the hook's ERC-6909 ETH balance at the PoolManager equals `totalOwed()`, which is the sum
of every open or sealed pot plus every unclaimed winning. The hook itself never holds ETH.

### Tickets and identity

Each swap whose ETH leg is at least 0.001 ETH pushes one ticket for its identity onto the current round;
smaller swaps pay the fee but get no ticket. The identity is `abi.decode(hookData, (address))` when
`hookData` is exactly 32 bytes and encodes a non-zero address. Anything else (empty data, other lengths,
the zero address, a word with dirty upper bytes) credits nobody, so a router that forwards no data can
never claim. **`hookData` is unauthenticated:** whoever builds the swap chooses which address gets the
ticket. This is by design for a test toy; it means a ticket proves that *someone* paid the fee for that
address, not that the address itself traded.

### Rounds, seal, draw, claim

1. Swaps land in round `r = block.timestamp / 3600`. A swap after round `r` ends always lands in a later
   round, so a closed round never gains tickets or pot.
2. After round `r` ends, anyone calls `seal(poolKey, r)`. It records `targetBlock = block.number + 1`,
   once. Sealing a running or future round reverts (`RoundNotEnded`); sealing twice reverts
   (`RoundNotOpen`).
3. While `targetBlock < block.number <= targetBlock + 256`, anyone calls `draw(poolKey, r)`:
   `winner = tickets[uint256(keccak256(abi.encode(blockhash(targetBlock), poolId, r))) % ticketCount]`
   and the whole pot is credited to `winnings[winner]`. Calling at or before `targetBlock` reverts
   (`TargetBlockNotReached`).
4. If the round has no tickets, or `draw` is first called after `targetBlock + 256` (when the hash is no
   longer available), the pot rolls into the round current at that call (`RolledOver`). The receiving
   round is always open, because only ended rounds can be sealed.
5. Each round draws or rolls exactly once; a second `draw` reverts (`RoundNotSealed`). No pot is lost:
   it is either paid to exactly one winner or moved, whole, into a later round.
6. `claim()` pays the caller. A winner that cannot receive ETH sees its claim revert and keeps its
   balance; there is no alternate recipient.

Events: `Ticket(poolId, round, holder, index)`, `Sealed(poolId, round, targetBlock)`,
`Drawn(poolId, round, winner, pot)`, `RolledOver(poolId, round, toRound, pot)`, `Claimed(account, amount)`.

Views: `currentRound()`, `pot(poolId, round)`, `ticketCount(poolId, round)`,
`ticketsOf(poolId, round, user)`, `ticketAt(poolId, round, index)`, `roundState(poolId, round)`
(status, pot, ticketCount, targetBlock, winner, rolledInto), `winnings(account)`, `totalOwed()`.

### Randomness: what it is and is not

The draw uses `blockhash(targetBlock)` where `targetBlock` is the block after the seal. **A Sepolia
proposer can bias this by withholding a block**, and the sealer chooses which block becomes the target.
There is no VRF, oracle or keeper. This is acceptable only because pots are test-toy sized. The
`% ticketCount` reduction has a modulo bias of at most `ticketCount / 2^256`, which is negligible.

## Deployment parameters (`src/LaunchParams.sol`)

| Parameter | Value |
| --- | --- |
| Chain | Sepolia (11155111) |
| PoolManager (hook constructor argument) | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Pool key | `currency0` = native ETH (`address(0)`), `currency1` = TIKT, `fee` = 3000, `tickSpacing` = 60, `hooks` = SwapLotteryHook |
| Hook address bits | `0x00CC`, mined with `HookMiner.find(create2Deployer, HookFlags.SWAP_LOTTERY, creationCode)` |
| Initial tick / manifest price | tick `161160`, `sqrtPriceX96 = 250178251749461638198017379368160` (≈ 9,971,028 TIKT per ETH) |
| Seed position | TIKT only, range `[-887220, 161160]` (up to and including the initial tick), liquidity `LaunchParams.seedLiquidity()` = `158343425058399045465466`, pulling ≈ 500,000,000 TIKT |
| Token supply | 1,000,000,000 TIKT, 18 decimals, minted to the factory |

Assumptions behind these numbers:

- The factory initializes the pool at the manifest price and seeds one-sided TIKT liquidity. Because
  the pool is ETH/TIKT with ETH as `currency0`, a TIKT-only position must sit at or below the current
  tick; the rehearsal uses the full range below the initial tick. The hook has no initialize or
  liquidity permissions, so it cannot revert either step regardless of the exact range the factory uses.
- The initial price and the 50 % seed are proposals for the manifest. Changing them changes nothing in
  the hook; only `LaunchParams` and the rehearsal test would move.
- Sepolia block time ≈ 12 s, so the 256-block draw window is roughly 51 minutes.

## Operational responsibilities

Nobody is privileged, but somebody has to act for a round to resolve:

- **Seal** each ended round (`seal`). Until then the pot simply sits, still fully backed by claims.
- **Draw** within 256 blocks of the target block. If nobody does, the pot is not lost: the first later
  `draw` rolls it into the round current at that moment.
- **Claim** is pull-based; winners call `claim()` themselves. Unclaimed winnings stay claimable forever.
- The site (built in a later step) should show seal and draw buttons when due and the current pot; the
  hook does not depend on it.

Gas: a qualifying swap adds one `push` and one counter update (about 45k gas on top of the swap). There
are no loops over tickets anywhere, so rounds cannot grow into an out-of-gas condition.

## Test suite

Run against a real v4-core `PoolManager` deployed in the test, with the hook at a mined address and the
`PoolSwapTest` / `PoolModifyLiquidityTest` routers.

- `LaunchRehearsal.t.sol`: initialize at the manifest price, seed one-sided TIKT liquidity like the
  factory, first buy into the ETH-less pool, the deploy script's shape.
- `SwapLotteryHook.fees.t.sol`: permissions (and constructor rejection of wrong address bits), every
  callback refuses non-PoolManager callers, all four swap modes with exact swapper amounts, dust, partial
  fills in three shapes, fuzzed sizes for all four modes, a non-ETH pool, bounded ticket gas.
- `SwapLotteryHook.lottery.t.sol`: inclusive ticket threshold, ETH-leg threshold for unspecified-ETH
  swaps, identity rules, round boundary at the hour, sealed rounds gain nothing, seal timing and
  double seal, draw before seal, draw at `targetBlock` / `+1` / `+256` / `+257`, empty rounds, double
  draw, rollover once and chained rollovers, winner formula and ticket weights, claim (zeroing, second
  claim, non-winner, accumulation, reentrancy, settlement failure), pots + winnings == claims through a
  full lifecycle.
- `SwapLotteryHook.invariant.t.sol`: handler-driven invariants — claims == totalOwed == fees − claimed,
  open pots + winnings == totalOwed, the current round is never sealed.
- `Ticket.t.sol`: metadata, fixed supply, no admin entry points, exact transfers.

Tests passing are not a security audit. The independent adversarial review targets the blockhash window
off-by-ones, timing games around `seal`, ticket index bias, round-boundary assignment, rollover double
counting, claim reentrancy and ticket-array gas.

## Unresolved deployment choices

- The manifest's initial price and seed amount (proposed above) are the manifest assignment's to confirm.
- The Sepolia `PoolSwapTest` router address the site swaps through is named in the site step, not here.
- This repository authorizes no transaction and controls no wallet; the factory deploys, the services
  publish, attest and admit.
