# LinkUs Protocol — Smart Contracts

Contrats Solidity (Foundry) de LinkUs Protocol : identité soulbound, token de
gouvernance, staking, tips, contenus monétisés, gouvernance DAO. Déployés et
**vérifiés sur Etherscan (Sepolia testnet)** — le code ici correspond au
source publié on-chain, republié dans ce miroir pour faciliter la lecture,
les contributions et les audits externes.

> ⚠️ **Testnet, non audité.** Vérifié sur Etherscan ne veut pas dire audité.
> Aucun audit de sécurité externe n'a encore été réalisé. Ne pas déployer sur
> mainnet ni utiliser avec des fonds réels en l'état.

## Build & test

```bash
forge install    # récupère forge-std + OpenZeppelin (submodules)
forge build --via-ir
forge test
```

## Contrats déployés (Sepolia)

**Suite V8** — déployée le 2026-05-07 :

| Contrat | Adresse | Rôle |
|---|---|---|
| `LksCoreV8` | [`0xE3cf3ED52b3d889d2f3ED4C8D40E46Ee31483a85`](https://sepolia.etherscan.io/address/0xE3cf3ED52b3d889d2f3ED4C8D40E46Ee31483a85) | Cœur (tiers, réputation, abonnements) — UUPS |
| `LksTipVault` | [`0x0c6Fb09D5F5D8cc2BcDd30d23f93B713De15E98f`](https://sepolia.etherscan.io/address/0x0c6Fb09D5F5D8cc2BcDd30d23f93B713De15E98f) | Tips (pull pattern) |
| `LksTier1155` | [`0x38625a6698f025B42640eaDC8aE5C6c38B544c4E`](https://sepolia.etherscan.io/address/0x38625a6698f025B42640eaDC8aE5C6c38B544c4E) | Tiers d'accès (ERC-1155) |
| `LksContent1155` | [`0x9c0C0c0B4d64b338b85Bc273a13318Ba938De2fA`](https://sepolia.etherscan.io/address/0x9c0C0c0B4d64b338b85Bc273a13318Ba938De2fA) | Contenus monétisés (ERC-1155) |
| `LksBusinessV8` | [`0xCFD39a2a94e1d9D8796035dAFEfF00AF52884BB9`](https://sepolia.etherscan.io/address/0xCFD39a2a94e1d9D8796035dAFEfF00AF52884BB9) | Projets, marketplace, financement |

**Socle V7** (identité, token, staking, gouvernance) :

| Contrat | Adresse | Rôle |
|---|---|---|
| `LksIdentityV2` | [`0xF8B31321Cd8649A76efBBd4B364795F51ea9F933`](https://sepolia.etherscan.io/address/0xF8B31321Cd8649A76efBBd4B364795F51ea9F933) | Identité soulbound (ERC-5192), non-upgradeable |
| `LKST` | [`0x508E94C06526E040cb66D78dd404CD16a45fdF22`](https://sepolia.etherscan.io/address/0x508E94C06526E040cb66D78dd404CD16a45fdF22) | Token de gouvernance (ERC20Votes) |
| `LKSV` | [`0x15E4F931C46797c72A268887A1b103E565ECaBf3`](https://sepolia.etherscan.io/address/0x15E4F931C46797c72A268887A1b103E565ECaBf3) | Staking vault (ERC4626) |
| `LksGovernance` | [`0xB9368210A6ec657FEBaab759467aDe5ce0cE29dc`](https://sepolia.etherscan.io/address/0xB9368210A6ec657FEBaab759467aDe5ce0cE29dc) | DAO Governor (OpenZeppelin) |
| `LKSTimelock` | [`0x35578098aA253B74DD5bc457e7Ba43C0231C8EEf`](https://sepolia.etherscan.io/address/0x35578098aA253B74DD5bc457e7Ba43C0231C8EEf) | Timelock controller (2 jours) |

## Structure

```
src/
├── core/          # LksCoreV8 — tiers, réputation, registre de modules
├── identity/       # LksIdentityV2 — NFT soulbound ERC-5192
├── token/          # LKST (ERC20Votes) + LKSV (ERC4626 staking)
├── social/         # LksSocialModule — posts, tips (pull pattern), follows
├── business/       # LksBusinessV8 — projets, marketplace, financement
├── tier/, content/, tips/   # ERC-1155 tiers + contenus + tip vault
├── governance/     # LksGovernance (Governor) + LKSTimelock
├── paymaster/      # ERC-4337 paymaster
└── shared/         # Erreurs et modifiers communs

test/
├── *.t.sol          # tests unitaires par contrat
├── integration/     # scénarios de bout en bout
├── invariants/      # tests d'invariants (fuzzing stateful)
├── fuzz/            # tests de fuzzing
└── sim/             # cross-validation des formules économiques
```

## Voir aussi

- [`../docs/`](../docs) — gouvernance multisig, stratégie d'upgrade,
  méthodologie de test, couverture, audit du bytecode déployé.
