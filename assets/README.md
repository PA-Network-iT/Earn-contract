# PAiT NFT IPFS Assets

Off-chain metadata and media for `SubscriptionNFT` and `SubscriptionManager` Level tiers.

## Layout

```
assets/
├── subscription/
│   ├── image.svg          # static art for PAiT Subscription NFT
│   └── metadata.json
├── package-pass/
│   ├── pass.svg           # symlink → subscription/image.svg (replace with tier art later)
│   └── tiers/
│       ├── 1-entry/
│       │   ├── animation.webm
│       │   └── metadata.json
│       ├── 2-core/ …
│       ├── 3-growth/ …
│       ├── 4-pro/ …
│       └── 5-elite/ …
└── tiers.manifest.json    # deploy helper (prices/seats + metadataURI placeholders)
```

## Upload to IPFS

Pin the whole `assets/` directory (Pinata, Lighthouse, etc.) so relative paths in JSON resolve correctly.

Example with Pinata CLI:

```bash
pinata upload assets/ --name pait-nft-assets-v1
```

After upload, set each `metadataURI` in `tiers.manifest.json`, then call on-chain:

```solidity
// price in USDC 6 decimals, e.g. 1000 USDC = 1000e6
manager.addTier(1000e6, 20, "ipfs:///package-pass/tiers/1-entry/metadata.json");
```



## On-chain mapping

| Asset | Used by |
|---|---|
| `subscription/metadata.json` | future `tokenURI` for `SubscriptionNFT` |
| `package-pass/tiers/*/metadata.json` | `SubscriptionManager.addTier(..., metadataURI)` |

`suggestedPriceUsdc` and `seats` in `tiers.manifest.json` match the frontend tier catalog; confirm final prices before mainnet deploy.

## Notes

- `image` and `animation_url` use paths relative to each `metadata.json` file.
- Level NFTs are soulbound; metadata is stored per tier in `SubscriptionManager`, not per token.
- Replace `package-pass/pass.svg` with dedicated tier artwork when ready.
