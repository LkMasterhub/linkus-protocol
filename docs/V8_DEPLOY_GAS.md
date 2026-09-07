# V8 Deploy + Gas Baseline — Phase 4

**Date** : 2026-05-07
**Branche** : `webv9-wasm` (V8 clean-slate WIP)
**Tests** : 333 V8 onchain + 4 smoke E2E intégration verts

---

## 1. Résumé Phase 4

| Critère | Cible | Atteint |
|---|---|---|
| `script/DeployV8.s.sol` atomique | obligatoire | ✅ 5 contrats + 4 modules wirés en 1 tx |
| Dry-run anvil | obligatoire | ✅ Gas total **11.2 M** |
| Smoke E2E intégration | obligatoire | ✅ 4 tests, full cycle tip→withdraw→subscribe→purchase→fund→refund |
| Gas baseline figé | obligatoire | ✅ `docs/audit/v8/gas/gas-report.txt` (791 lignes) |
| ABIs export | livrable | ✅ `docs/audit/v8/abi/*.json` (5 fichiers) |
| Storage layouts export | livrable | ✅ `docs/audit/v8/storage/*.txt` (5 fichiers) |
| Slither helper | livrable | ✅ `scripts/run-slither-v8.sh` (no-op si binary absent) |

---

## 2. DeployV8.s.sol — 5 contrats + wiring atomique

```
1. LksTipVault       (non-upgradeable)              — constructor(admin, feeBps, treasury)
2. LksCoreV8         (UUPS impl + ERC1967 proxy)    — initialize(admin, treasury)
3. LksTier1155       (UUPS impl + ERC1967 proxy)    — initialize(admin, treasury, uri)
4. LksContent1155    (UUPS impl + ERC1967 proxy)    — initialize(admin, treasury, earnSigner, feeBps, uri)
5. LksBusinessV8     (UUPS impl + ERC1967 proxy)    — initialize(admin, treasury, feeBps)

6. core.registerModule(MODULE_TIPVAULT,    tipVault)
   core.registerModule(MODULE_TIER1155,    tier)
   core.registerModule(MODULE_CONTENT1155, content)
   core.registerModule(MODULE_BUSINESS,    business)
```

**Variables d'environnement** :
- `DEPLOYER_PRIVATE_KEY` (obligatoire)
- `TREASURY` (default = deployer)
- `EARN_SIGNER` (default = deployer ; **prod = KMS dédié**)
- `PLATFORM_FEE_BPS` (default = 250 = 2.5 %)

**Sanity assertions post-broadcast** : 4 `require(core.getModule(...) == addr)` qui revertent si un wiring n'est pas appliqué (impossible en pratique car `registerModule` revert sur erreur, mais safety net pour audit).

**Gas dry-run anvil** : 11,188,649 (≈ 11.2 M). Bien sous une transaction Ethereum mainnet (block limit ~30 M). Sepolia : aucun problème.

---

## 3. Gas baseline — fonctions critiques

### LksTipVault
| Fonction | Min | Avg | Median | Max | Calls |
|---|---:|---:|---:|---:|---:|
| `tip` | 24,321 | 81,302 | 95,635 | 95,851 | 1580 |
| `withdraw` | 28,601 | 32,322 | 32,351 | 32,351 | 266 |
| `withdrawPlatformFees` | 28,805 | 51,986 | 62,123 | 62,123 | 6 |

### LksCoreV8
| Fonction | Avg | Notes |
|---|---:|---|
| `addReputation` | ~30k | WRITER_ROLE only |
| `slashReputation` | ~30k | WRITER_ROLE only |
| `registerModule` | ~50k | REGISTRY_ADMIN_ROLE |
| `getTier` | ~3k | view, read-through Tier1155 |

### LksTier1155
| Fonction | Min | Avg | Median | Max | Calls |
|---|---:|---:|---:|---:|---:|
| `subscribe` | 28,458 | 84,990 | 51,415 | 176,818 | 3829 |
| `cancelAndRefund` | 34,301 | 89,262 | 91,020 | 91,020 | 269 |

### LksContent1155
| Fonction | Min | Avg | Median | Max | Calls |
|---|---:|---:|---:|---:|---:|
| `registerContent` | 30,032 | 106,293 | 102,364 | 124,949 | 1323 |
| `purchase` | 29,622 | 97,075 | 93,651 | 179,310 | 8791 |
| `withdrawEarnings` | 34,065 | 35,968 | 37,858 | 37,858 | 518 |

### LksBusinessV8
| Fonction | Min | Avg | Median | Max | Calls |
|---|---:|---:|---:|---:|---:|
| `createProject` | 29,246 | 98,172 | 98,501 | 98,513 | 1328 |
| `fund` | 29,310 | 65,886 | 65,914 | 65,914 | 6063 |
| `refund` | 36,570 | 45,169 | 45,178 | 45,178 | 3030 |
| `withdrawFunds` | 34,248 | 59,893 | 72,570 | 72,570 | 781 |

**Observations** :
- Toutes les fonctions write critiques restent **< 200k gas** en pic, médianes < 100k.
- `purchase` à 179k max correspond au premier mint d'un token (storage init ERC1155Supply) — comportement attendu OZ.
- Pas de fonction qui s'approche dangereusement du budget block (30M).

Source complète : `docs/audit/v8/gas/gas-report.txt` (791 lignes, 333 tests).

---

## 4. Smoke E2E — `test/integration/DeployV8.t.sol`

4 tests vert :

| Test | Couverture |
|---|---|
| `test_Smoke_DeploymentWired` | Vérifie 4 modules wirés + treasury propagé partout |
| `test_Smoke_FullCycle` | tip → withdraw → subscribe → purchase → fund → refund |
| `test_Smoke_BalanceAccountingAcrossContracts` | TipVault + Content fees indépendants malgré treasury commun |
| `test_Smoke_TreasuryConsolidation` | 3 withdrawPlatformFees → treasury reçoit cumul exact (tip+content+crowdfund) |

Le test reproduit fidèlement `script/DeployV8.s.sol` puis exécute le cycle complet. **Aucune fixture mockée** — chaque transaction émise est une vraie tx, chaque assert vérifie un état post-tx.

---

## 5. Dossier audit — `docs/audit/v8/`

```
docs/audit/v8/
├── abi/                          5 fichiers JSON (forge inspect <C> abi)
│   ├── LksTipVault.json          13 KB
│   ├── LksCoreV8.json            21 KB
│   ├── LksTier1155.json          27 KB
│   ├── LksContent1155.json       37 KB
│   └── LksBusinessV8.json        24 KB
├── storage/                      5 fichiers TXT (forge inspect <C> storage-layout)
│   ├── LksTipVault.txt           Storage slots détaillés avec __gap
│   ├── LksCoreV8.txt
│   ├── LksTier1155.txt
│   ├── LksContent1155.txt
│   └── LksBusinessV8.txt
├── gas/
│   └── gas-report.txt            Rapport complet 333 tests, 791 lignes
├── slither/                      stub si binary absent (run via scripts/run-slither-v8.sh)
└── mythril/                      vide (mythril nécessite Docker, à activer Phase 6)
```

### Régen

```bash
# ABIs + storage
cd contractv5
forge build --build-info
for c in LksTipVault LksCoreV8 LksTier1155 LksContent1155 LksBusinessV8; do
  forge inspect $c abi > ../docs/audit/v8/abi/${c}.json
  forge inspect $c storage-layout > ../docs/audit/v8/storage/${c}.txt
done

# Gas report
forge test --match-contract "(LksTipVaultTest|LksCoreV8Test|LksTier1155Test|LksContent1155Test|LksBusinessV8Test|DeployV8Smoke)" --gas-report > ../docs/audit/v8/gas/gas-report.txt

# Slither (optionnel, requires `pip install slither-analyzer`)
bash scripts/run-slither-v8.sh
```

### Mythril (Phase 6)

Mythril sera exécuté en Phase 6 (soak Sepolia) via Docker :

```bash
docker run -v $(pwd)/contractv5:/src mythril/myth analyze \
    /src/src/tips/LksTipVault.sol \
    --solv 0.8.20 \
    --solc-args "--via-ir --optimize --optimize-runs 200" \
    -o markdown > docs/audit/v8/mythril/LksTipVault.md
```

À répéter pour les 5 contrats V8. Findings High → patcher avant audit externe.

---

## 6. Statut Phase 4

| Critère | Atteint |
|---|---|
| DeployV8.s.sol atomique | ✅ |
| Dry-run anvil 11.2 M gas | ✅ |
| Smoke E2E 4/4 verts | ✅ |
| Gas baseline figé | ✅ |
| ABIs + storage exportés | ✅ |
| Slither helper script | ✅ |
| Mythril dossier structuré | ✅ stub Phase 6 |

**Cumul cumulatif Solidity** : 619 + 4 smoke = **623 tests verts**.
**Phase 4 livrée.**

---

## 7. Suite — Phase 5 Frontend webV9 V8

1. Régénérer ABIs côté frontend : copier `docs/audit/v8/abi/*.json` vers `frontend/webV9/src/lib/services/abis/`
2. Créer 5 services TS : `tip.service.ts`, `tier.service.ts`, `content.service.ts`, `coreV8.service.ts`, `businessV8.service.ts`
3. Réécrire routes `/staking`, `/subscriptions`, `/governance`, `/token`, `/crowdfunding` pour V8 ABIs
4. Créer route `/content/[tokenId]/+page.svelte` (ERC1155 view + purchase)
5. `.env` : remplir adresses V8 post-déploiement Sepolia (variable explicite user)
6. Warning V7 deprecated dans `/admin` et `/cycle`

**Critère sortie Phase 5** : `npm run check` 0/0/0, `npm run build` vert, toutes routes V8.
