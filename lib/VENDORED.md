# Vendored dependencies

Every dependency is committed as ordinary files (no git submodules) so the project builds offline.

| Library | Upstream | Commit / tag | Files kept |
| --- | --- | --- | --- |
| forge-std | https://github.com/foundry-rs/forge-std | 3e2295d50379faa6c8e9859d51b1f97a69a830d1 | `src/` |
| v4-core | https://github.com/Uniswap/v4-core | 46c6834698c48bc4a463a86d8420f4eb1d7f3b75 | `src/`, `test/utils/CurrencySettler.sol`, `test/utils/LiquidityAmounts.sol`, `licenses/` |
| solmate | https://github.com/transmissions11/solmate | 89365b880c4f3c786bdd453d4b8e8fe410344a69 | `src/auth/Owned.sol` (required by v4-core `ProtocolFees`) |
| openzeppelin-contracts | https://github.com/OpenZeppelin/openzeppelin-contracts | v5.4.0 (c64a1edb67b6e3f4a15cca8909c9482ad33a02b0) | `contracts/token/ERC20/{ERC20,IERC20}.sol`, `contracts/token/ERC20/extensions/IERC20Metadata.sol`, `contracts/utils/Context.sol`, `contracts/interfaces/draft-IERC6093.sol` |

Only the files the project imports are kept. Nothing was modified.
