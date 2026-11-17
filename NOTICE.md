# Third-party code

- `contracts/uniswap-artifacts/` holds compiled artifacts of Uniswap v3 (UniswapV3Factory, NonfungiblePositionManager). They are used by the tests only and stay under Uniswap's own licences. They are not part of the Tidewell contracts.
- Libraries (OpenZeppelin, Uniswap v4, Permit2, solmate, forge-std) are downloaded by `contracts/install-deps.sh` at pinned versions. They stay under their own licences.
