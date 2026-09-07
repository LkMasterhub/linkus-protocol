# V8 Bytecode Audit — Phase 2.8

**Date** : 2026-05-07
**Branche** : `webv9-wasm` (V8 clean-slate WIP)
**Compilateur** : solc 0.8.20 + via_ir + optimizer 200 runs
**Limite EIP-170** : 24,576 B (runtime) / EIP-3860 : 49,152 B (initcode)
**Seuil d'alerte projet** : 90 % du budget runtime (= 22,118 B)

---

## 1. Résumé exécutif

| Statut | Contrats V8 |
|---|---|
| ✅ Sous le seuil d'alerte (< 90 % budget) | 5 / 5 contrats V8 inédits |
| ✅ Sous EIP-170 (24,576 B) | 5 / 5 |
| ⚠ Au-dessus de 60 % budget | 1 / 5 (`LksContent1155` à 64.7 %) |
| 🟢 Headroom moyen V8 | **~70 % du budget runtime libre** |

**Verdict** : aucun contrat V8 ne dépasse 16 KB runtime. Le plus volumineux (`LksContent1155`, 15,897 B) consomme 64.7 % du budget EIP-170, laissant **8,679 B de marge** pour des extensions UUPS futures (storage migrations, hooks, ERC2981 enrichissement). Aucune extraction de library n'est nécessaire à ce stade.

---

## 2. Tableau bytecode complet — Contrats V8 inédits

| Contrat | Type | Runtime (B) | Initcode (B) | Runtime margin (B) | Budget consommé |
|---|---|---:|---:|---:|---:|
| `LksTipVault` | non-upgradeable | **2,999** | 3,865 | 21,577 | **12.2 %** |
| `LksBusinessV8` | UUPS | **7,629** | 7,860 | 16,947 | **31.0 %** |
| `LksCoreV8` | UUPS | **7,691** | 7,922 | 16,885 | **31.3 %** |
| `LksTier1155` | UUPS + ERC1155 | **12,849** | 13,080 | 11,727 | **52.3 %** |
| `LksContent1155` | UUPS + ERC1155 + ERC2981 + EIP-712 | **15,897** | 16,128 | 8,679 | **64.7 %** |

**Total runtime V8 (5 contrats)** : 47,065 B
**Total initcode V8 (5 contrats)** : 48,855 B

---

## 3. Contrats V8 réutilisés sans modification

| Contrat | Runtime (B) | Margin (B) | Budget % | Notes |
|---|---:|---:|---:|---|
| `LksIdentityV2` (inchangé V7) | 11,719 | 12,857 | 47.7 % | Soulbound ERC-5192 non-upgradeable, score audit 8.5/10 |
| `LKSTUpgradeable` | 15,340 | 9,236 | 62.4 % | ERC20Votes + Permit, surveiller si extensions futures |
| `LKSVUpgradeableV3` | 10,887 | 13,689 | 44.3 % | ERC4626 + reward formula corrigée |
| `LksGovernanceUpgradeable` | 14,182 | 10,394 | 57.7 % | Fixes V7 (LKS-GOV-04/05/08/09) |
| `LKSTimelockUpgradeable` | 9,457 | 15,119 | 38.5 % | Fix DEFAULT_ADMIN_ROLE V7 |

---

## 4. Analyse contrat par contrat

### 4.1 `LksTipVault` — 2,999 B (12.2 %)

Le plus petit contrat V8. Surface minimale : `tip(author)` payable + `withdrawTips()` pull pattern + `setFeeBps()` admin + Pausable. Pas d'ERC1155, pas d'UUPS (non-upgradeable). Headroom **21,577 B** disponibles si futur ajout de batching ou subscription tips.

### 4.2 `LksBusinessV8` — 7,629 B (31.0 %)

Crowdfunding pull-pattern. Coût raisonnable malgré 6 fonctions principales (createProject/fund/withdrawFunds/refund/cancelProject/withdrawPlatformFees) + `_statusOf()` calc dynamique. Headroom **16,947 B** pour extensions futures (vesting, milestones, multi-sig).

### 4.3 `LksCoreV8` — 7,691 B (31.3 %)

Registry + tiers + reputation + Pausable. Volontairement minimal (pas de logique tier/subscription embarquée — déléguée à `LksTier1155`). Le pattern read-through `getTier()` via `try/catch` sur module externe maintient la taille faible. Headroom **16,885 B**.

### 4.4 `LksTier1155` — 12,849 B (52.3 %)

ERC1155 + ERC1155Supply + UUPS + AccessControl + Pausable + ReentrancyGuard + override `_update()` pour soulbound. La couche ERC1155Supply ajoute ~3 KB par rapport à ERC1155 nu. Headroom **11,727 B**.

### 4.5 `LksContent1155` — 15,897 B (64.7 %) ⚠ Plus gros V8

ERC1155 + ERC1155Supply + ERC2981 + EIP-712 + UUPS + AccessControl + Pausable + ReentrancyGuard + ECDSA recovery. Ajout d'EIP-712 (~1.5 KB) + ERC2981 royalty registry (~1 KB) + ECDSA verify earnAccess (~0.8 KB) explique les 3 KB supplémentaires vs `LksTier1155`. **Headroom 8,679 B** — confortable mais doit être surveillé si :
- ajout future d'ERC1155URIStorage (~2 KB)
- ajout d'ERC2981 multi-receiver (~1 KB)
- migration storage UUPS V2 (~0.5 KB initialisation)

**Recommandation** : si dépassement futur de 90 % budget (= 22,118 B), extraire `LksFeeSim` math en library externe (économie ~0.3 KB) ou déplacer EIP-712 typehash en library.

---

## 5. Comparaison V8 vs V7 (gains de réécriture)

| Domaine | V7 contrat | V7 size (B) | V8 contrat | V8 size (B) | Δ |
|---|---|---:|---|---:|---:|
| Business | `LksBusinessModule` | 21,155 | `LksBusinessV8` | 7,629 | **−13,526** (−64 %) |
| Core | `LksCoreUpgradeable` | 9,727 | `LksCoreV8` | 7,691 | **−2,036** (−21 %) |
| Social/Tip | `LksSocialModule` | 12,597 | `LksTipVault` | 2,999 | **−9,598** (−76 %) ⚠ |

⚠ **Note social** : `LksTipVault` n'est pas un remplaçant 1:1 de `LksSocialModule`. La logique posts/likes/follows est migrée **off-chain** (lks-core Rust crate `lks-social`) per la décision 2026-04-24 (privacy-first). `LksTipVault` ne couvre que la dimension tips on-chain. La comparaison reste pertinente pour valider qu'on n'a pas perdu de fonctionnalités on-chain critiques (les tips sont préservés ; les posts sont devenus off-chain par design).

**Total runtime V8 inédits** : 47,065 B vs équivalent V7 (LksBusinessModule + LksCoreUpgradeable + LksSocialModule + LksSubscription) ~50,000+ B → **gain net ~6 % + introduction de Tier1155 + Content1155 nouveaux**.

---

## 6. Initcode (EIP-3860 — 49,152 B)

Aucun contrat V8 ne s'approche de la limite initcode. Le plus gros initcode V8 est `LksContent1155` à **16,128 B**, soit **32.8 %** du budget initcode. Marges très confortables.

---

## 7. Recommandations

| Priorité | Recommandation | Justification |
|---|---|---|
| ✅ Aucune action requise | Maintenir l'architecture actuelle | Tous les contrats V8 sous 65 % du budget runtime |
| 🟡 Surveillance | Mesurer `forge build --sizes` à chaque PR Phase 2 | Alerte si `LksContent1155` dépasse 22,118 B (90 %) |
| 🟡 Surveillance | Vérifier `LKSTUpgradeable` (62.4 %) avant ajout extension | ERC20Votes + Permit déjà coûteux |
| 🟢 Optionnel | Documenter pattern `LksFeeSim` library externe | Plan B si Content1155 dépasse seuil futur |
| 🟢 Optionnel | Considérer `LksRoyaltyLib` extraction si ERC2981 multi-receiver ajouté | Économie estimée 0.5–1 KB |

---

## 8. Méthodologie

```bash
cd contracts
forge build --sizes --via-ir
```

Les tailles rapportées sont :
- **Runtime size** : bytecode déployé (limite EIP-170 = 24,576 B sur Ethereum)
- **Initcode size** : bytecode constructor + runtime (limite EIP-3860 = 49,152 B Shanghai+)
- **Margin** : `24,576 − runtime size`

Conventions du compilateur :
- `via_ir = true` (active le pipeline IR Yul, généralement +1–3 % runtime mais optimisations plus agressives)
- `optimizer_runs = 200` (optimisé pour deploy + run modéré, vs runs=10000 pour très chaud)

Pour audit externe, fournir aussi :
```bash
forge build --sizes --via-ir | grep -E "Lks|LKS" > docs/audit/v8-bytecode-baseline.txt
forge inspect <Contract> abi > docs/audit/abi/<Contract>.json
forge inspect <Contract> storageLayout > docs/audit/storage/<Contract>.json
```

---

## 9. Référence — Limites Ethereum

| Limite | Valeur | EIP | Activée |
|---|---:|---|---|
| Runtime bytecode | 24,576 B | EIP-170 | Spurious Dragon (2016) |
| Initcode | 49,152 B | EIP-3860 | Shanghai (2023) |
| Single transaction gas | 30,000,000 | — | London+ |
| Block gas limit | ~30,000,000 | — | dynamique |

---

## 10. Statut Phase 2.8

| Critère | Cible | Atteint |
|---|---|---|
| Tous V8 < EIP-170 (24,576 B) | obligatoire | ✅ 5/5 |
| Tous V8 < seuil alerte 90 % (22,118 B) | recommandé | ✅ 5/5 (max 64.7 %) |
| Headroom ≥ 5 KB pour upgrades futurs | recommandé | ✅ min 8,679 B (`LksContent1155`) |
| Documentation baseline | livrable | ✅ ce document |

**Phase 2.8 livrée**. Prochaine étape : **P2.9 coverage gates global** (≥80 % lines, ≥75 % branches par contrat, script CI bloquant).
