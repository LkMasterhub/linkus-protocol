# V8 Sepolia Deployment — 2026-05-07

**Date** : 2026-05-07
**Branche** : `webv9-wasm`
**Status** : ✅ **9/9 contrats déployés et vérifiés sur Etherscan**
**Deployer** : `0x5ba49Ad8F21729cf062348846E25542F2c3Dc8bD`
**RPC** : `https://rpc.ankr.com/eth_sepolia` (authed)

---

## 1. Adresses canoniques V8 Sepolia

### Contrats user-facing (à utiliser dans le frontend)

| Contrat | Adresse Sepolia | Etherscan |
|---|---|---|
| **LksTipVault** (non-upgradeable) | `0x0c6Fb09D5F5D8cc2BcDd30d23f93B713De15E98f` | [view](https://sepolia.etherscan.io/address/0x0c6fb09d5f5d8cc2bcdd30d23f93b713de15e98f) |
| **LksCoreV8** (UUPS proxy) | `0xe3cf3eD52B3d889d2F3eD4c8D40e46EE31483a85` | [view](https://sepolia.etherscan.io/address/0xe3cf3ed52b3d889d2f3ed4c8d40e46ee31483a85) |
| **LksTier1155** (UUPS proxy) | `0x38625a6698f025B42640eaDC8aE5C6c38B544c4E` | [view](https://sepolia.etherscan.io/address/0x38625a6698f025b42640eadc8ae5c6c38b544c4e) |
| **LksContent1155** (UUPS proxy) | `0x9c0C0c0B4d64b338b85Bc273a13318Ba938De2fA` | [view](https://sepolia.etherscan.io/address/0x9c0c0c0b4d64b338b85bc273a13318ba938de2fa) |
| **LksBusinessV8** (UUPS proxy) | `0xCFD39a2a94e1d9D8796035dAFEfF00AF52884BB9` | [view](https://sepolia.etherscan.io/address/0xcfd39a2a94e1d9d8796035dafeff00af52884bb9) |

### Implementations UUPS (référence — ne pas appeler directement)

| Contrat | Adresse impl Sepolia |
|---|---|
| LksCoreV8 impl | `0xe0a3f78805ecffdb39bcd67017d3f68a819632ad` |
| LksTier1155 impl | `0x7e9eaf44d49ff81409db4dffb9a018025c0f4161` |
| LksContent1155 impl | `0x86A9068CdF1c546f64C911f65922cce075A0a33C` |
| LksBusinessV8 impl | `0x4Ce81C425287C15256D0c616065dC3238334c5BE` |

---

## 2. Configuration runtime (post-deploy)

### Paramètres initialisés

| Paramètre | Valeur |
|---|---|
| `admin` | `0x5ba49Ad8F21729cf062348846E25542F2c3Dc8bD` (deployer) |
| `treasury` | `0x5ba49Ad8F21729cf062348846E25542F2c3Dc8bD` (deployer) |
| `earnSigner` (Content1155) | `0x5ba49Ad8F21729cf062348846E25542F2c3Dc8bD` (deployer) |
| `platformFeeBps` | 250 (2.5 %) — sur TipVault, Content1155, BusinessV8 |
| Tier1155 base URI | `https://link-us.fr/api/tier/{id}.json` |
| Content1155 base URI | `https://link-us.fr/api/content/{id}.json` |

### Sanity checks on-chain (vérifiés post-deploy)

```bash
$ cast call $CORE "getModule(bytes32)(address)" $TVKEY --rpc-url $RPC_URL
0x0c6Fb09D5F5D8cc2BcDd30d23f93B713De15E98f   ← TipVault wirée

$ cast call $CORE "getModule(bytes32)(address)" $TIERKEY --rpc-url $RPC_URL
0x38625a6698f025B42640eaDC8aE5C6c38B544c4E   ← Tier1155 wirée

$ cast call $CORE "getModule(bytes32)(address)" $CONTENTKEY --rpc-url $RPC_URL
0x9c0C0c0B4d64b338b85Bc273a13318Ba938De2fA   ← Content1155 wirée

$ cast call $CORE "getModule(bytes32)(address)" $BIZKEY --rpc-url $RPC_URL
0xCFD39a2a94e1d9D8796035dAFEfF00AF52884BB9   ← BusinessV8 wirée

$ cast call $TIPVAULT "feeBps()(uint16)" --rpc-url $RPC_URL
250
$ cast call $TIPVAULT "feeRecipient()(address)" --rpc-url $RPC_URL
0x5ba49Ad8F21729cf062348846E25542F2c3Dc8bD
$ cast call $TIPVAULT "paused()(bool)" --rpc-url $RPC_URL
false
```

---

## 3. Coût gas

| Élément | Valeur |
|---|---|
| Total gas DeployV8 | ~11.2 M (dry-run anvil) |
| Sepolia gas price typique | ~10–50 gwei |
| Coût ETH estimé | ~0.1–0.5 ETH |
| Solde deployer post-deploy | reste largement > 2 ETH (balance pré ~2.7 ETH) |

Vérification on-chain de l'usage gas réel à faire via Etherscan tx history.

---

## 4. Vérification Etherscan

```
Submitting verification for [src/tips/LksTipVault.sol:LksTipVault]              → Pass - Verified
Submitting verification for [src/core/LksCoreV8.sol:LksCoreV8]                  → Pass - Verified
Submitting verification for [src/tier/LksTier1155.sol:LksTier1155]              → Pass - Verified
Submitting verification for [src/content/LksContent1155.sol:LksContent1155]     → Pass - Verified
Submitting verification for [src/business/LksBusinessV8.sol:LksBusinessV8]      → Pass - Verified
Submitting verification for [ERC1967Proxy] × 4                                   → All Verified
```

**All (9) contracts verified on Etherscan.**

---

## 5. Frontend webV9 — Mise à jour

### `.env` mis à jour

```
PUBLIC_LKS_V8_TIPVAULT=0x0c6Fb09D5F5D8cc2BcDd30d23f93B713De15E98f
PUBLIC_LKS_V8_CORE=0xe3cf3eD52B3d889d2F3eD4c8D40e46EE31483a85
PUBLIC_LKS_V8_TIER1155=0x38625a6698f025B42640eaDC8aE5C6c38B544c4E
PUBLIC_LKS_V8_CONTENT1155=0x9c0C0c0B4d64b338b85Bc273a13318Ba938De2fA
PUBLIC_LKS_V8_BUSINESS=0xCFD39a2a94e1d9D8796035dAFEfF00AF52884BB9
```

### `config/contracts.ts` — `SEPOLIA_V8_CONTRACTS`

Hardcodé en fallback même si `.env` vide → la config Sepolia est résiliente.
Anvil mode (chainId 31337) reste opérationnel via `getV8Contracts()` qui retourne `ANVIL_V8_CONTRACTS`.

### Vérification

```bash
cd frontend/webV9
pnpm run check    # 0/0/0 — vert
pnpm run build    # vite build vert
```

---

## 6. Étapes suivantes (Phase 6 soak)

| # | Étape | Status |
|---|---|---|
| 6.1 | Deploy Sepolia | ✅ **fait 2026-05-07** |
| 6.2 | Update CLAUDE.md + diagram.pen avec adresses V8 finales | ⏳ |
| 6.3 | Brief testers (~10) : V7 abandonné, V8 sur nouvelles adresses | ⏳ |
| 6.4 | Monitoring 30j : events emis, balance invariants, gas patterns | ⏳ rolling |
| 6.5 | Slither + mythril sur les 5 contrats V8 | ⏳ (script `run-slither-v8.sh` prêt) |
| 6.6 | Préparer dossier audit complet : NatSpec export, threat model `SECURITY.md` | ⏳ |
| 6.7 | Brief auditeur externe (Trail of Bits / ChainSecurity / Spearbit) | ⏳ |

---

## 7. Smoke tests à exécuter (manuels, browser)

1. `pnpm run dev` (avec `.env` Sepolia) → `http://127.0.0.1:5173`
2. Connect MetaMask sur Sepolia, switch wallet vers `0x5ba4…c8bD` (admin) ou un autre compte testeur
3. **Subscriptions** : visiter `/subscriptions` → tier configs vides initialement (admin doit `setTierConfig` avant). Note : le DeployV8 ne configure pas les tiers — c'est une étape admin séparée.
4. **Crowdfunding** : créer un projet (goal 0.01 ETH, durée 1h) → fund → withdraw post-deadline. ✅ smoke OK.
5. **Content** : `registerContent` puis purchase via `/content/[tokenId]`. ✅ flow validé.
6. **Tip** : naviguer `/feed`, sélectionner un post V6 existant, tip via TipVault → withdraw.

⚠ **Action admin requise pour /subscriptions** : `tier.setTierConfig(1, ...)`, `tier.setTierConfig(2, ...)`, `tier.setTierConfig(3, ...)` à appeler une seule fois pour activer les 3 tiers.

---

## 8. Adresses V6 (legacy — ne plus utiliser pour writes)

```
LksIdentityV2    0xF8B31321Cd8649A76efBBd4B364795F51ea9F933  ✅ conservé V8 (inchangé)
LKST             0x508E94C06526E040cb66D78dd404CD16a45fdF22  ✅ conservé V8 (inchangé)
LKSV V2          0x15E4F931C46797c72A268887A1b103E565ECaBf3  ⚠ V3 deferred
LksGovernance    0xB9368210A6ec657FEBaab759467aDe5ce0cE29dc  ✅ conservé V8 (fixes)
LKSTimelock      0x35578098aA253B74DD5bc457e7Ba43C0231C8EEf  ✅ conservé V8 (fix)
LksCore V6       0x0b2CdFd41c2Ab1BAD5F9b2FA27E1C6d1ebd9DA3A  ❌ remplacé par LksCoreV8
LksBusiness V6   0x00D0990aFCfC0B41e351DAe0f3844814C92B9EBA  ❌ remplacé par LksBusinessV8
LksSocial V6     0x1a024e685ad27BA38661Ea409FeffB0809D6af9e  ⚠ posts/likes encore lus, tips migrés V8
```

---

## 9. Référence broadcast log

`contractv5/broadcast/DeployV8.s.sol/11155111/run-latest.json` — log complet des 9 transactions de déploiement, à conserver pour audit historique.

---

## Cumul V8 (toutes phases)

| Phase | Status | Highlight |
|---|---|---|
| P1 Specs + Simulators | ✅ | 26 sim + 20 proptest |
| P2 Implémentations on-chain | ✅ | 616 tests + 17 invariants + bytecode + coverage |
| P3 Off-chain hardening | ✅ | MultiSigEntry + cross-validation Sol↔Rust 0 wei drift |
| P4 Deploy + smoke | ✅ | DeployV8 + smoke E2E + gas baseline + audit dossier |
| P5 Frontend webV9 | ✅ | 5 services TS + 4 routes V8 |
| **P6.1 Sepolia deploy** | ✅ **fait** | **9/9 contrats verified, 4 modules wirés** |
| P6.2-6.7 soak + audit prep | ⏳ rolling | Monitoring + slither + mythril + auditor brief |

**V8 est désormais consultable on-chain Sepolia.**
