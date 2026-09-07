# V8 Test Methodology — Ableton-grade

**Statut** : Phase 1.6 (canonique). Appliqué dès Phase 2.
**Source du verdict "Ableton-grade"** : audit interne de la V7 ayant relevé 0 invariant Foundry, 2 fuzz tests seulement, ~217 tests pour 9 contrats — insuffisant pour un audit externe budgeté ~$60-100k. La V8 vise audit-ready dès la fin de Phase 2.

---

## 1. Six règles non-négociables

### Règle 1 — Asserts forts seulement

```solidity
// ❌ banni
assertGt(reward, 0);

// ✅ requis
assertEq(reward, LksRewardSim.earnedAt(userShares, totalSupply, rate, …));
```

Tout test qui ne sait pas calculer la valeur attendue à la main n'est pas un test, c'est un smoke test.

### Règle 2 — Reference simulator obligatoire pour la math

Quatre simulators figés en Phase 1.4 (`contractv5/test/sim/`) :

| Simulator | Couvre | Tolérance type |
|---|---|---|
| `LksTipSim` | TipVault.tip / withdraw | **exact** (`assertEq`) |
| `LksFeeSim` | Content1155.purchase, BusinessV8.withdrawFunds, ERC2981 royalty | exact |
| `LksTierSim` | Tier1155.subscribe / cancelAndRefund | exact |
| `LksRewardSim` | LKSV V3 rewardPerToken / earned | `assertApproxEqAbs(_, totalSupply / 1e18 + 1)` (rounding ERC4626) |

**Règle de cross-validation** : tout test de fonction financière implémentation-native doit comparer son résultat avec `LksXxxSim.compute(args)`.

### Règle 3 — Cycle complet sur tout test temporel

```solidity
function test_subscribe_extends_existing_expiry() public {
    // setup : Alice subscribed jusqu'à T+30d
    vm.warp(0);
    tier.subscribe{value: 1 ether}(2);  // PREMIUM
    uint64 e0 = tier.expiryOf(alice, 2);
    assertEq(e0, 30 days);

    // action : Alice re-subscribe à T+5d
    vm.warp(5 days);
    tier.subscribe{value: 1 ether}(2);

    // assert : expiry = max(now, e0) + 30d = e0 + 30d
    uint64 e1 = tier.expiryOf(alice, 2);
    uint64 expected = LksTierSim.newExpiry(e0, 5 days, 30 days);
    assertEq(e1, expected);
    assertEq(e1, 60 days); // sanity manuelle
}
```

Pas de tests qui s'arrêtent juste après le setup. Tout flow doit aller `setup → vm.warp → action → assertEq(state, expected)`.

### Règle 4 — Invariants Foundry (≥ 20)

Configuration `foundry.toml` :

```toml
[invariant]
runs       = 256
depth      = 50
fail_on_revert = false
call_override = false
```

Profile `reward` pour Synthetix-style staking : `runs = 10000`.

20 invariants ciblés (cf. `V8_CONTRACTS.md` §7) répartis sur 5 handlers :
- `TipVaultHandler` → INV-01 à INV-04, INV-11, INV-17, INV-18
- `CoreHandler` → INV-09, INV-10, INV-16, INV-18, INV-19
- `TierHandler` → INV-09 à INV-12, INV-20
- `ContentHandler` → INV-11, INV-13, INV-18
- `BusinessHandler` → INV-13 à INV-15

### Règle 5 — Fuzz tests (≥ 25, ciblés financier)

```toml
[fuzz]
runs    = 256
seed    = "0x..."  # figé pour reproductibilité CI
max_test_rejects = 65536
```

Profile `deep` pour tests critiques : `runs = 10000`.

25 fuzz cibles :
- 4 TipVault (split, postTotals, paused, fee cap)
- 4 CoreV8 (rep, registry, getTier)
- 4 Tier1155 (expiry, refund proportional, soulbound, max supply)
- 4 Content1155 (purchase split, royalty bound, mintCount, withdraw idempotent)
- 5 BusinessV8 (fund, refund, withdraw, deadline, double-call)
- 4 cross-contract (tier-gated, content via core, governance flow)

### Règle 6 — Coverage gates en CI

```bash
forge coverage --report lcov
scripts/check-coverage.sh   # exit 1 si < 80 % lines ou < 75 % branches sur src/
```

Cible :
- contrats financiers (Tip, Tier, Content, BusinessV8) : ≥ 90 % lines, ≥ 80 % branches
- core (CoreV8, governance, timelock) : ≥ 80 % lines, ≥ 75 % branches
- libraries (sim, errors, modifiers) : 100 % lines

Le script check-coverage.sh est bloquant en CI.

---

## 2. Nomenclature

```
test/
├── unit/
│   ├── LksTipVault.t.sol           # 55 tests asserts forts
│   ├── LksCoreV8.t.sol
│   ├── LksTier1155.t.sol
│   ├── LksContent1155.t.sol
│   └── LksBusinessV8.t.sol
├── invariants/
│   ├── TipVaultHandler.t.sol
│   ├── CoreHandler.t.sol
│   ├── TierHandler.t.sol
│   ├── ContentHandler.t.sol
│   └── BusinessHandler.t.sol
├── fuzz/
│   └── LksFuzz.t.sol               # 25 fuzz groupés
├── integration/
│   ├── DeployV8.t.sol              # smoke E2E in-test
│   └── CrossContract.t.sol
└── sim/
    ├── LksTipSim.sol               # ✅ Phase 1.4
    ├── LksFeeSim.sol               # ✅
    ├── LksTierSim.sol              # ✅
    ├── LksRewardSim.sol            # ✅
    └── Simulators.t.sol            # ✅ 26 tests
```

---

## 3. Pattern d'un test "Ableton-grade"

```solidity
/// @notice Tests TipVault.tip() — happy path + edge cases.
contract LksTipVaultTest is Test {
    LksTipVault vault;
    address constant ALICE = address(0xa11ce);
    address constant BOB   = address(0xb0b);
    uint16  constant FEE_BPS = 250; // 2.5 %

    function setUp() public {
        vault = new LksTipVault(address(this), FEE_BPS, address(0xfee));
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB,   100 ether);
    }

    // ─── Happy path ───────────────────────────────────────────

    function test_Tip_creditsAuthorAndPlatformExact() public {
        uint256 amount = 1 ether;
        uint256 postId = 42;
        (uint256 expectedAuthor, uint256 expectedFee) =
            LksTipSim.split(amount, FEE_BPS);

        vm.prank(ALICE);
        vault.tip{value: amount}(postId, BOB);

        assertEq(vault.tipsOwed(BOB), expectedAuthor);
        assertEq(vault.platformFees(), expectedFee);
        assertEq(address(vault).balance, amount);
        // event check
        // …
    }

    // ─── Edge cases ───────────────────────────────────────────

    function test_Tip_revertsBelowMinTip() public {
        vm.prank(ALICE);
        vm.expectRevert(LksErrors.TipBelowMinimum.selector);
        vault.tip{value: 1}(1, BOB);
    }

    function test_Tip_revertsZeroAuthor() public {
        vm.prank(ALICE);
        vm.expectRevert(LksErrors.NullAuthor.selector);
        vault.tip{value: 1 ether}(1, address(0));
    }

    function test_Tip_revertsWhenPaused() public {
        vault.pause();
        vm.prank(ALICE);
        vm.expectRevert(); // OZ Pausable revert
        vault.tip{value: 1 ether}(1, BOB);
    }

    // ─── Fuzz ─────────────────────────────────────────────────

    function testFuzz_Tip_splitMatchesSim(uint256 amount) public {
        amount = bound(amount, vault.MIN_TIP(), 10 ether);
        (uint256 expectedAuthor, uint256 expectedFee) =
            LksTipSim.split(amount, FEE_BPS);
        vm.prank(ALICE);
        vault.tip{value: amount}(1, BOB);
        assertEq(vault.tipsOwed(BOB), expectedAuthor);
        assertEq(vault.platformFees(), expectedFee);
    }
}
```

---

## 4. Off-chain proptest harness

`lks-core/crates/domains/{lks-social,lks-id-profile}/tests/proptest.rs`.
(`lks-rep` et `lks-biz` supprimés le 2026-08-06 — voir CORE_TEST_MATRIX.)

5 invariants par domaine = 20 squelettes en Phase 1.5 (livré, 20/20 verts).

Cibles d'extension Phase 3 :
- 5 invariants additionnels par domaine via `proptest_state_machine` (séquence d'opérations)
- Cross-validation Solidity ↔ Rust pour `LksTipSim` : porter le simulator en Rust pur dans `lks-core/crates/sim/` et fuzzer 1000 valeurs identiques côté Solidity et Rust → diff ≤ 1 wei.

---

## 5. WASM browser tests (Phase 3)

```rust
// lks-core/crates/wasm/lks-api-wasm/tests/browser.rs
use wasm_bindgen_test::*;
wasm_bindgen_test_configure!(run_in_browser);

#[wasm_bindgen_test]
fn signed_frame_roundtrip_chrome() {
    // produit la même signature que validator natif
    // …
}
```

Exécution : `wasm-pack test --headless --firefox crates/wasm/lks-api-wasm`.

---

## 6. CI bloquant

```yaml
- name: forge test
  run: cd contractv5 && forge test --no-match-test 'invariant_'  # unit + fuzz
- name: forge invariant
  run: cd contractv5 && forge test --match-contract Invariant -vvv
- name: coverage gate
  run: cd contractv5 && scripts/check-coverage.sh
- name: cargo test
  run: cd lks-core && cargo test --workspace
- name: cargo clippy
  run: cd lks-core && cargo clippy --workspace --all-targets -- -D warnings
- name: wasm tests
  run: cd lks-core && wasm-pack test --headless --firefox crates/wasm/lks-api-wasm
```

Tout job rouge bloque le merge. Pas de `--ignore` ou `--skip` non documenté.

---

## 7. Anti-patterns explicitement bannis

- ❌ `assertGt(reward, 0)` sans valeur attendue
- ❌ `assertTrue(success)` sans vérifier l'effet de bord
- ❌ Tests qui dépendent de `block.timestamp` réel sans `vm.warp`
- ❌ Mock contrats sans simulator de référence
- ❌ Setup partagé via `setUp()` qui mute des state-vars utilisées en lecture par d'autres tests (use `forge test --no-match-` au lieu)
- ❌ `try/catch` qui swallow l'erreur sans assert sur le selector
- ❌ Tests qui passent quand l'implémentation revert pour une raison non testée (utiliser `vm.expectRevert(SpecificError.selector)`)
- ❌ Back-door admin functions (`resetXxx`, `setBalance`, `forceWithdraw`) — interdites en V8.

Tout PR contenant un anti-pattern est bloqué en review.
