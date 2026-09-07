# V8 Contracts — Spécification canonique

**Statut** : Phase 1 (specs + simulators figés). Phase 2 (implémentations) ⏳.
**Branche** : `v8-clean-slate` (contractv5/).
**Solidity** : 0.8.20, OZ Upgradeable, Foundry, via_ir + optimizer 200.

V8 abandonne V7 déployée Sepolia. Pas de migration utilisateur (`webv9-wasm` clean-wipe). Les adresses V7 restent en historique mais sont considérées dépréciées.

---

## 1. Inventaire (7 contrats)

| # | Contrat | Type | LoC cible | Notes |
|---|---|---|---|---|
| 1 | `LksIdentityV2` | non-upgradeable, ERC-5192 | (inchangé) | Conservé tel quel, audit 8.5/10. |
| 2 | `LksTipVault` ⭐ | non-upgradeable, ETH custody | ~120 | Tips push-payable + pull `withdraw()`. Isolé. |
| 3 | `LksCoreV8` | UUPS | ~400 | Registry + tier (read-through) + reputation + pause. |
| 4 | `LksTier1155` ⭐ | UUPS + ERC1155 | ~300 | Soulbound. tokenId ∈ {1,2,3} = BASIC/PREMIUM/PRO. |
| 5 | `LksContent1155` ⭐ | UUPS + ERC1155 + ERC2981 | ~450 | tokenId déterministe = `keccak(creator, contentCid)`. |
| 6 | `LksBusinessV8` | UUPS | ~350 | Crowdfunding seul. Métadonnées délégué à Content1155. |
| 7 | `LksGovernanceV8` + `LKSTimelockV8` | UUPS | (V7 fixes) | Renommage V8 + fixes LKS-GOV-04/05/08/09 + LKS-TL-01. |

**Conservés sans changement structurel** :
- `LKSTUpgradeable` (ERC20Votes) — passe en V8 sous le même nom.
- `LKSVUpgradeableV2` → V3 avec fix formule reward (cf. `LKSV_REWARD_FORMULA.md`).

---

## 2. Interfaces (Phase 1.3 livrée)

Toutes les interfaces canoniques sont dans `contractv5/src/*/I*.sol`. Les tests sont écrits **contre l'interface, pas l'implémentation**.

### 2.1 ITipVault (`src/tips/ITipVault.sol`)

Surface minimale ETH custody :

```solidity
event Tipped(uint256 indexed postId, address indexed author, address indexed sender, uint256 authorShare, uint256 platformFee);
event Withdrawn(address indexed author, uint256 amount);
event PlatformFeesWithdrawn(address indexed recipient, uint256 amount);
event FeeUpdated(uint16 oldBps, uint16 newBps);

function tip(uint256 postId, address author) external payable;
function withdraw() external;
function withdrawPlatformFees(address to) external;

// reads
function tipsOwed(address) external view returns (uint256);
function platformFees() external view returns (uint256);
function feeBps() external view returns (uint16);
function MAX_FEE_BPS() external view returns (uint16); // 3000 (30 %)
function MIN_TIP() external view returns (uint256);    // 1e13 wei
```

Reference simulator : **LksTipSim**.
Invariants ciblés : INV-01 à INV-04.

### 2.2 ILksCoreV8 (`src/core/ILksCoreV8.sol`)

```solidity
struct TierData {
    uint8  tier;        // 0 = none, 1..3 mapped to LksTier1155 token id
    uint48 expiry;      // ts unix (seconds), 0 si pas d'expiration
    uint96 reputation;  // points off-chain mirroring (capped)
    bool   flagged;     // gel manuel (DAO/admin)
}

event TierUpdated(address indexed user, uint8 oldTier, uint8 newTier, uint48 expiry);
event ReputationChanged(address indexed user, uint96 oldRep, uint96 newRep, bytes32 reasonId);
event ModuleRegistered(bytes32 indexed key, address contractAddr);
event Flagged(address indexed user, bool flagged);

function getTier(address user) external view returns (uint8);
function getReputation(address user) external view returns (uint96);
function isFlagged(address user) external view returns (bool);

function addReputation(address user, uint96 amount, bytes32 reasonId) external; // SOCIAL_WRITER / BIZ_WRITER
function slashReputation(address user, uint96 amount, bytes32 reasonId) external; // ADMIN_WRITER

function registerModule(bytes32 key, address impl) external;       // REGISTRY_ADMIN
function flag(address user, bool isFlagged) external;              // MOD_WRITER
```

`getTier()` lit à travers `LksTier1155` (read-through, pas de duplication d'état) — le registry gère la résolution.

### 2.3 ITier1155 (`src/tier/ITier1155.sol`)

```solidity
struct TierConfig {
    uint128 price;       // wei
    uint64  duration;    // seconds
    uint64  maxSupply;   // 0 = unlimited
    bool    active;
}

event Subscribed(address indexed user, uint8 indexed tierId, uint64 newExpiry, uint128 paid);
event Cancelled(address indexed user, uint8 indexed tierId, uint256 refund);
event TierConfigured(uint8 indexed tierId, uint128 price, uint64 duration, uint64 maxSupply, bool active);

function subscribe(uint8 tierId) external payable;
function cancelAndRefund(uint8 tierId) external;

function balanceOf(address account, uint256 id) external view returns (uint256); // ∈ {0, 1}
function expiryOf(address user, uint8 tierId) external view returns (uint64);
function isActive(address user, uint8 tierId) external view returns (bool);
function configOf(uint8 tierId) external view returns (TierConfig memory);

function setTierConfig(uint8 tierId, TierConfig calldata cfg) external; // ADMIN

// soulbound: safeTransferFrom + safeBatchTransferFrom revert toujours
```

Reference simulator : **LksTierSim**.
Invariants ciblés : INV-09, INV-10, INV-12, INV-18, INV-20.

### 2.4 IContent1155 (`src/content/IContent1155.sol`)

```solidity
struct ContentMeta {
    address  creator;
    uint128  price;        // wei (0 = gratuit)
    uint64   maxSupply;    // 0 = unlimited
    uint16   royaltyBps;   // ERC2981 royalty (≤ 10000)
    uint64   mintCount;
    bytes32  contentCid;   // pointeur off-chain (iroh blake3 / IPFS)
    bool     soulbound;    // si true: revert transfer
}

event ContentRegistered(uint256 indexed tokenId, address indexed creator, bytes32 contentCid, uint128 price, uint16 royaltyBps);
event Purchased(uint256 indexed tokenId, address indexed buyer, uint128 paid, uint128 creatorShare, uint128 platformFee);
event AccessEarned(uint256 indexed tokenId, address indexed earner, bytes32 nonce);
event EarningsWithdrawn(address indexed creator, uint256 amount);

function registerContent(bytes32 contentCid, uint128 price, uint64 maxSupply, uint16 royaltyBps, bool soulbound) external returns (uint256 tokenId);
function purchase(uint256 tokenId) external payable;
function earnAccess(uint256 tokenId, bytes32 nonce, uint64 deadline, bytes calldata sig) external; // EIP-712
function withdrawEarnings() external;

function metaOf(uint256 tokenId) external view returns (ContentMeta memory);
function tokenIdOf(address creator, bytes32 contentCid) external pure returns (uint256);
function pendingEarnings(address creator) external view returns (uint256);

// ERC2981
function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount);
```

`tokenId = uint256(keccak256(abi.encodePacked(creator, contentCid)))` — déterministe, pas d'ID counter.

Reference simulator : **LksFeeSim**.
Invariants ciblés : INV-11, INV-12, INV-13, INV-19.

### 2.5 ILksBusinessV8 (`src/business/ILksBusinessV8.sol`)

Crowdfunding minimal :

```solidity
enum ProjectStatus { NONE, ACTIVE, FUNDED, REFUNDABLE, CANCELLED, WITHDRAWN }

struct Project {
    address       creator;
    uint64        deadline;
    uint128       goal;
    uint128       raised;
    ProjectStatus status;
}

event ProjectCreated(uint256 indexed projectId, address indexed creator, uint128 goal, uint64 deadline);
event Funded(uint256 indexed projectId, address indexed funder, uint128 amount, uint128 newRaised);
event WithdrawnFunds(uint256 indexed projectId, address indexed creator, uint128 amount, uint128 platformFee);
event Refunded(uint256 indexed projectId, address indexed funder, uint128 amount);
event Cancelled(uint256 indexed projectId);

function createProject(bytes32 slugHash, uint128 goal, uint64 deadline) external returns (uint256 projectId);
function fund(uint256 projectId) external payable;
function withdrawFunds(uint256 projectId) external;
function refund(uint256 projectId) external;
function cancelProject(uint256 projectId) external; // creator only, before deadline

function projectOf(uint256 projectId) external view returns (Project memory);
function projectIdOf(address creator, bytes32 slugHash) external pure returns (uint256);
function fundingOf(uint256 projectId, address funder) external view returns (uint128);
```

Reference simulator : **LksFeeSim** (fee split sur withdraw).
Invariants ciblés : INV-13, INV-14, INV-15.

---

## 3. Erreurs partagées

`src/shared/LksErrors.sol` centralise. Aucun `require(bool, string)` autorisé.

Catégories :
- **General** : `ZeroAddress`, `ZeroAmount`, `Unauthorized`, `Paused`, `AlreadyInitialized`.
- **TipVault** : `NullAuthor`, `FeeTooHigh`, `TipBelowMinimum`, `NoTipsToWithdraw`.
- **CoreV8** : `InvalidTier`, `ReputationCapExceeded`, `ModuleNotRegistered`.
- **Tier1155** : `TierNotActive`, `MaxSupplyReached`, `AlreadySubscribed`, `NotSubscribed`, `Soulbound`.
- **Content1155** : `ContentAlreadyRegistered`, `RoyaltyTooHigh`, `MaxMintReached`, `InvalidSignature`, `NonceUsed`, `SignatureExpired`.
- **BusinessV8** : `ProjectNotFound`, `DeadlinePassed`, `DeadlineNotPassed`, `GoalNotReached`, `GoalReached`, `AlreadyWithdrawn`, `AlreadyRefunded`, `NotCreator`.

---

## 4. Modifiers partagés

`src/shared/LksModifiers.sol` (library, pas contrat) :

```solidity
function requireIdentityHolder(address identityContract, address account) internal view;
function requireMinTier(address coreContract, address account, uint8 minTier) internal view;
function requireAuthorized(bool condition) internal pure;
```

Les contrats inheritent leur propre `Pausable` + `AccessControl` ; les modifiers ci-dessus sont des helpers `staticcall` cross-contract.

---

## 5. Patterns transverses imposés

1. **Custom errors only** — zéro `require(bool, string)`.
2. **NatSpec exhaustive** : `@notice`, `@param`, `@return`, `@dev`. Findings cités explicitement.
3. **Tout write émet un event** avec `before` et `after` pour les mutations numériques.
4. **`external`** partout sur l'ABI. `internal` pour les helpers.
5. **Storage packed avec comments** : `// slot N : <contenu> — <raison du packing>`.
6. **Reference simulators Solidity-pure** comparés via `assertApproxEqRel(actual, sim.compute(args), 1e14)` (0.01 % tolerance).
7. **Pull pattern strict** pour les transferts ETH (CEI).
8. **`try/catch`** sur tout cross-contract call non-trivial.
9. **Pas de back-doors admin** — `resetUserRewards`, `setBalance`, etc. **bannies**. L'admin agit via `Pausable` + `upgradeToAndCall(timelock)`.

---

## 6. Architecture Core ↔ Modules ↔ ERC1155

```
                  ┌────────────────────────┐
                  │    LksIdentityV2       │  ERC-5192 soulbound
                  └────────────────────────┘
                              ▲
                              │ requireIdentityHolder
                              │
   ┌──────────────────────────┼──────────────────────────────────┐
   │                          │                                  │
┌───────────────┐    ┌─────────────────┐    ┌──────────────────────────┐
│ LksTipVault   │    │   LksCoreV8     │    │   LksTier1155 (ERC1155)  │
│ (ETH custody) │    │ registry+rep    │◄──►│ subscriptions soulbound  │
└───────────────┘    │ +pause+tier rd  │    └──────────────────────────┘
                     └─────────────────┘                ▲
                              ▲                          │ getTier read-through
                              │ addReputation            │
                              │ slashReputation          │
                  ┌───────────┴─────────────┐            │
                  │                          │           │
        ┌──────────────────────┐    ┌──────────────────────────┐
        │ LksBusinessV8        │    │   LksContent1155 (ERC1155+ERC2981) │
        │ crowdfunding         │    │   content NFTs + royalties         │
        └──────────────────────┘    └────────────────────────────────────┘

   ┌────────────┐    ┌────────────┐    ┌──────────────────┐
   │  LKST V8   │◄──►│ LKSV V3    │    │ LksGovernanceV8  │
   │ (Votes)    │ stk│ (4626 fix) │    │ + LKSTimelockV8  │
   └────────────┘    └────────────┘    └──────────────────┘
```

---

## 7. Métriques cibles V8 stable

- ~420 tests cumulés Foundry (275 unit + 20 invariants + 25 fuzz + 30 integration + simulators)
- Coverage ≥80 % lines, ≥75 % branches sur tout contrat financier
- Bytecode < 24 KB EIP-170 par contrat (`forge build --sizes`)
- Reference simulator-cross-validé pour toute math
- Gas baseline figé Phase 4 (`forge snapshot`)

Voir `V8_TEST_METHODOLOGY.md` pour les règles de test détaillées.
