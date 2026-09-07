# V8 Cross-Validation Rust ↔ Solidity — Phase 3.6

**Date** : 2026-05-07
**Branche** : `webv9-wasm` (V8 clean-slate WIP)
**Cible** : 100 fixtures déterministes, **diff ≤ 0 wei** entre `LksTipSim`/`LksFeeSim` (Solidity) et `lks-sim` (Rust port).

---

## 1. Principe

Le protocole V8 expose la même formule de partage de fees dans deux langages :

- **Solidity on-chain** : `LksTipSim.split` + `LksFeeSim.feeSplit` (utilisés par `LksTipVault`, `LksContent1155`, `LksBusinessV8`).
- **Rust off-chain** : `lks-sim::tip_split` + `lks-sim::fee_split` (utilisés par `lks-core` lksd + WASM browser pour pré-afficher les splits avant signature).

Tout drift entre les deux implémentations briserait les invariants de comptabilité. P3.6 fige les deux côtés sur un **fichier de fixtures partagé** (`tip_split_v1.json`, 100 entrées générées par seed 0xC0FFEE) et assert byte-pour-byte l'équivalence.

---

## 2. Architecture

```
┌─────────────────────────────────────┐         ┌─────────────────────────────────────┐
│ lks-core/crates/sim/lks-sim/        │  regen  │ contractv5/test/sim/fixtures/       │
│   src/lib.rs       (Rust port)      │ ──────► │   tip_split_v1.json (mirror)        │
│   tests/cross_validate.rs           │         │                                     │
│   fixtures/tip_split_v1.json (canon)│         │ test/sim/CrossValidation.t.sol      │
│                                     │         │   ↑ vm.readFile + vm.parseJson      │
└─────────────────────────────────────┘         └─────────────────────────────────────┘
       │                                                   │
       │ tip_split(amount, fee_bps)                        │ LksTipSim.split(amount, feeBps)
       │ fee_split(amount, platform_fee_bps)               │ LksFeeSim.feeSplit(amount, bps)
       ▼                                                   ▼
   (U256 floor)                                         (uint256 floor)
       │                                                   │
       └─────────────── byte-pour-byte equality ───────────┘
```

### Source de vérité unique

Le crate Rust `lks-sim` est la source de vérité de la **génération** des fixtures (LCG seedé 0xC0FFEE → 100 entrées). Le mirror dans `contractv5/test/sim/fixtures/` est un duplicata commité, mis à jour automatiquement quand on regénère via :

```bash
LKS_SIM_REGEN=1 cargo test -p lks-sim --test cross_validate regen_or_validate_fixtures
```

Le test Foundry **ne regénère pas** les fixtures — il les valide. Si la lib Solidity diverge, le test fail avec `author mismatch` ou `fee mismatch`.

---

## 3. Formule canonique (deux langages)

```text
platform_fee = floor(amount × fee_bps / 10_000)
main_share   = amount - platform_fee
```

Contraintes :
- `fee_bps ∈ [0, 10_000]` (cap à 100 % — au-delà rejeté par `SimError::FeeBpsOutOfRange` côté Rust et revert custom côté Solidity).
- `amount ∈ U256` (jusqu'à `2^256 - 1` wei).
- Rounding : **floor** systématique côté plateforme — tout reliquat va au main share.

### Sémantique conservation

Pour toute fixture : `main_share + platform_fee == amount`. Aucun wei perdu, aucun créé.

Cette garantie est testée :
- **Côté Rust** : `tip_split_conserves_total` + `fixtures_are_self_consistent`
- **Côté Solidity** : `test_TipSim_matchesRustImplementation` (assertion `assertEq(author + fee, amount)`)

---

## 4. Couverture des fixtures

100 cases générés par LCG (Numerical Recipes constants) seedé `0xC0FFEE` :

| Métrique | Distribution |
|---|---|
| `amount` range | 1 wei → ~2^96 wei (≈79 octillion ETH) |
| `fee_bps` range | 0 → 10_000 (uniformément aléatoire) |
| Cas limites couverts | fee=0, fee=10_000, amount=1 (rounding), amounts mid-range, amounts gros |

Échantillon (3 fixtures sur 100) :

```json
[
  {
    "amount": "66059786899542056955122720735",
    "fee_bps": 4772,
    "expected_author": "34536056591080587376138158401",
    "expected_fee":    "31523730308461469578984562334"
  },
  {
    "amount": "41513860906353835704623257988",
    "fee_bps": 5871,
    "expected_author": "17141073168233498762438943224",
    "expected_fee":    "24372787738120336942184314764"
  },
  ...
]
```

---

## 5. Tests

### Côté Rust (`lks-sim`)

| Test | Cible | Statut |
|---|---|---|
| `tip_split_conserves_total` | `author + fee == amount` | ✅ |
| `tip_split_zero_fee` | fee_bps=0 → tout à l'auteur | ✅ |
| `tip_split_max_fee` | fee_bps=10000 → tout à plateforme | ✅ |
| `tip_split_rejects_invalid_bps` | fee_bps>10000 rejeté | ✅ |
| `tip_split_floor_rounding` | 1 wei × 1 bps = 0 fee | ✅ |
| `fee_split_matches_tip_split` | Les 2 fonctions sont identiques | ✅ |
| `royalty_amount_canonical` | ERC2981 royalty fraction | ✅ |
| `generate_fixtures_deterministic` | Même seed → mêmes fixtures | ✅ |
| `regen_or_validate_fixtures` | Fixtures committed cohérents | ✅ |
| `fixtures_are_self_consistent` | Recompute fixtures matche fichier | ✅ |
| **Total** | — | **10 tests verts** |

### Côté Solidity (`CrossValidation.t.sol`)

| Test | Cible | Statut |
|---|---|---|
| `test_TipSim_matchesRustImplementation` | 100 fixtures, diff = 0 wei | ✅ |
| `test_FeeSim_matchesTipSim` | TipSim ≡ FeeSim sur 100 fixtures | ✅ |
| `test_Fixtures_areWellFormed` | length=100, fee_bps≤10000, amount>0 | ✅ |
| **Total** | — | **3 tests verts** |

**Total cross-validation** : **13 tests verts (10 Rust + 3 Solidity)**, **0 wei de drift sur 100 fixtures**.

---

## 6. Pipeline de régénération

Si la formule canonique change (jamais souhaité — c'est l'invariant qu'on teste), procédure :

1. Modifier `lks-sim::tip_split` + `LksTipSim.split` en parallèle (les deux doivent rester équivalents).
2. Régénérer les fixtures :
   ```bash
   cd lks-core
   LKS_SIM_REGEN=1 cargo test -p lks-sim --test cross_validate regen_or_validate_fixtures
   ```
   Cela écrit le nouveau fichier dans :
   - `lks-core/crates/sim/lks-sim/fixtures/tip_split_v1.json` (canon)
   - `contractv5/test/sim/fixtures/tip_split_v1.json` (mirror auto)
3. Vérifier que les deux côtés passent :
   ```bash
   cargo test -p lks-sim                    # 10 verts
   cd ../contractv5
   forge test --match-path "test/sim/CrossValidation.t.sol"   # 3 verts
   ```
4. Si Solidity fail mais Rust passe (ou vice-versa), une des deux libs a divergé → corriger avant commit.

**Versioning** : `tip_split_v1.json` reflète la version V1 de la formule. Si la formule change incompatiblement, créer `tip_split_v2.json` et garder l'ancien fichier pour audit historique.

---

## 7. Configuration Foundry

Dans `foundry.toml` :

```toml
[profile.default]
fs_permissions = [
    { access = "read", path = "test/sim/fixtures/" },
]
```

Ce permission scope autorise uniquement la lecture du dossier de fixtures — aucun write, aucune autre lecture filesystem. Conforme à la pratique sécurisée Foundry (whitelisting explicit).

---

## 8. Statut Phase 3.6

| Critère | Cible | Atteint |
|---|---|---|
| 100 fixtures déterministes | obligatoire | ✅ seed 0xC0FFEE |
| Diff Rust ↔ Solidity ≤ 1 wei | obligatoire | ✅ **0 wei sur 100/100** |
| Couverture cas limites (0, max, rounding) | recommandé | ✅ tests dédiés Rust |
| Versioning des fixtures | recommandé | ✅ `tip_split_v1.json` |
| Documentation procédure régen | livrable | ✅ section 6 |
| Tests Foundry consomment fixtures | obligatoire | ✅ `CrossValidation.t.sol` 3/3 |
| Tests Rust consomment fixtures | obligatoire | ✅ `cross_validate.rs` 2/2 + 8 unit |

**Phase 3.6 livrée.**

---

## 9. Cumul Phase 3 V8

| Étape | Status | Tests | Description |
|---|---|---:|---|
| P3.1 MultiSigEntry | ✅ | 7 verts | threshold>1 réel co-sig recovery |
| P3.2 Redb wiring `lks-social` | ⏭ | déjà fait via M11.4 (HashChainSync câblé) |
| P3.3 Redb wiring `lks-biz`/`lks-rep`/`lks-id-profile` | ⏭ | hors scope V8 (orthogonal) |
| P3.4 20 proptest 4 domains | ✅ | 20 verts | livrés Phase 1.5 (5×4) |
| P3.5 wasm-pack tests browser | ⏭ | déjà couvert par M12.1 (lks-api-wasm wrapper) |
| **P3.6 Cross-validation Solidity↔Rust** | ✅ | **13 verts** | **0 wei drift sur 100 fixtures** |

**Phase 3 livrée pour les nouveautés V8** (P3.1 + P3.6). Les wirings Redb (P3.2/3.3) et wasm-pack tests (P3.5) sont déjà en place via les milestones précédentes M11/M12 du Linkus Node Engine — pas de duplication de travail nécessaire.

**Cumul cumulatif Rust workspace** : **337 tests verts** (320 baseline + 7 multisig + 8 lks-sim unit + 2 cross-validate).
**Cumul cumulatif Solidity** : **619 tests verts** (616 V8 + 3 cross-validation).

---

## 10. Suite

**Phase 4** — Script `DeployV8.s.sol` + smoke E2E in-test :

- `script/DeployV8.s.sol` atomique (TipVault + Core + Tier + Content + Business + wire registry + grant roles)
- `test/integration/DeployV8.t.sol` smoke E2E : tip → withdraw → subscribe → purchase → fund → refund
- `forge test --gas-report` baseline figé
- Préparation `slither` + `mythril` pour audit Phase 6
