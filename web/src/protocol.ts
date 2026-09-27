import { encodeAbiParameters, keccak256, parseAbi, parseAbiParameters, parseUnits, type Address } from 'viem';

// External interface fragments only. Deployed hook/token ABIs are loaded from the manifest.
export const poolKeyType = '(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)';
export const routerAbi = parseAbi([
  `function swap(${poolKeyType} key,(bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96) params,(bool takeClaims,bool settleUsingBurn) testSettings,bytes hookData) payable returns (int256 delta)`,
  'function manager() view returns (address)',
]);
export const stateAbi = parseAbi(['function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96,int24 tick,uint24 protocolFee,uint24 lpFee)', 'function poolManager() view returns (address)']);
export const quoterAbi = parseAbi([`function quoteExactInputSingle((${poolKeyType} poolKey,bool zeroForOne,uint128 exactAmount,bytes hookData) params) returns (uint256 amountOut,uint256 gasEstimate)`, 'function poolManager() view returns (address)']);
export type PoolKey = { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };
export type Round = { status: number; pot: bigint; ticketCount: bigint; targetBlock: bigint; winner: Address; rolledInto: bigint };
export const poolId = (key: PoolKey) => keccak256(encodeAbiParameters(parseAbiParameters(poolKeyType), [key]));
export const identity = (account: Address) => encodeAbiParameters([{ type: 'address' }], [account]);
export const MIN_SQRT = 4295128739n;
export const MAX_SQRT = 1461446703485210103287273052203988822378723970342n;

export function amountUnits(input: string, decimals: number) {
  if (!/^\d+(\.\d+)?$/.test(input) || (input.split('.')[1]?.length ?? 0) > decimals) throw new Error(`Enter a positive amount with at most ${decimals} decimal places.`);
  const value = parseUnits(input, decimals);
  if (value <= 0n || value >= 2n ** 127n) throw new Error('Enter a positive amount smaller than the pool limit.');
  return value;
}
export function sqrt(value: bigint): bigint {
  if (value < 0n) throw new Error('Negative square root');
  if (value < 2n) return value;
  let x = value;
  let y = (x + 1n) / 2n;
  while (y < x) { x = y; y = (x + value / x) / 2n; }
  return x;
}
export function priceLimit(price: bigint, buy: boolean, percent: string) {
  const bps = amountUnits(percent, 2);
  if (bps < 10n || bps > 500n) throw new Error('Choose a price movement limit from 0.1% to 5%.');
  // Conservative rounding: buy rounds up, sell down. The bound is on token1/token0 spot price.
  const scaled = price * price * (buy ? 10000n - bps : 10000n + bps) / 10000n;
  let limit = sqrt(scaled);
  if (buy && limit * limit < scaled) limit += 1n;
  if (limit <= MIN_SQRT || limit >= MAX_SQRT) throw new Error('Price limit exceeds the pool range.');
  return limit;
}
export function roundAction(round: Round, id: bigint, current: bigint, block: bigint): 'seal' | 'wait' | 'draw' | 'rollover' | 'finished' | 'open' {
  if (round.status === 2 || round.status === 3) return 'finished';
  if (id >= current) return 'open';
  if (round.status === 0) return 'seal';
  if (block <= round.targetBlock) return 'wait';
  return round.ticketCount === 0n || block > round.targetBlock + 256n ? 'rollover' : 'draw';
}
export function swapParams(key: PoolKey, account: Address, amount: bigint, buy: boolean, limit: bigint) {
  return [key, { zeroForOne: buy, amountSpecified: -amount, sqrtPriceLimitX96: limit }, { takeClaims: false, settleUsingBurn: false }, identity(account)] as const;
}
export function deltaOutput(packed: bigint, buy: boolean): bigint {
  return BigInt.asIntN(128, buy ? packed : packed >> 128n);
}
