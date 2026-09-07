# Stratégie d'Upgrade Smart Contracts LinkUs

## Recommandations par Contrat

### 🔄 **UPGRADEABLES (Pattern UUPS)**

#### 1. **LksCore** - CRITIQUE
```solidity
Raisons:
✅ Base de tous les contrats
✅ Rôles et permissions évolutifs
✅ Configuration protocole changeante
✅ Nouvelles fonctionnalités communes
✅ Corrections sécurité critiques

Pattern: UUPS (Ultra Upgrade Proxy Standard)
Contrôle: UPGRADER_ROLE restrictif
```

#### 2. **LksAccess** - ESSENTIEL
```solidity
Raisons:
✅ Règles d'accès métier évolutives
✅ Nouveaux types de données
✅ Conformité réglementaire (RGPD, etc.)
✅ Optimisations gas futures
✅ Intégrations enterprise

Pattern: UUPS
Contrôle: ADMIN_ROLE + gouvernance
```

#### 3. **LksProjects** - IMPORTANT
```solidity
Raisons:
✅ Modèles de financement évolutifs
✅ Mécanismes de vault DeFi
✅ Intégrations yield farming
✅ Nouveaux types de projets
✅ Optimisations économiques

Pattern: UUPS
Contrôle: Governance multi-sig
```

#### 4. **LksSocial** - OPTIONNEL
```solidity
Raisons:
✅ Features sociales évolutives
✅ Algorithmes de recommandation
✅ Intégrations externes
✅ UX et performance

Pattern: UUPS
Contrôle: ADMIN_ROLE
```

### 🔒 **NON-UPGRADEABLES (Immuables)**

#### 5. **LksIdentity** - IMMUABLE
```solidity
Raisons:
❌ Identité = confiance immutable
❌ NFT soulbound ne doit PAS changer
❌ Hash P2P stable requis
❌ Confiance utilisateurs critique
❌ Standard ERC721 établi

Alternative: Nouveau contrat + migration
```

#### 6. **LksToken** - IMMUABLE
```solidity
Raisons:
❌ Token = économie stable
❌ Supply et mécanismes figés
❌ Confiance investisseurs
❌ Intégrations exchanges
❌ Standard ERC20 établi

Alternative: Nouveau token + swap
```

## Architecture Technique

### UUPS vs Transparent Proxy

**UUPS Choisi** ✅
```solidity
Avantages:
+ Moins cher en gas (pas de delegation)
+ Contrôle dans l'implémentation
+ Plus sécurisé (upgrade logic protégé)
+ Compatible OpenZeppelin

Inconvénients:
- Risque si upgrade logic buggé
- Plus complexe à implémenter
```

### Pattern d'Implémentation

```solidity
// 1. Contrat Upgradeable
contract LksAccessUpgradeable is LksCoreUpgradeable {
    function initialize() public initializer {
        __LksCore_init(treasury);
    }

    // Storage gap pour futures versions
    uint256[50] private __gap;
}

// 2. Proxy Factory
contract LksProxyFactory {
    function deployUpgradeableAccess(
        address implementation,
        address admin,
        bytes memory data
    ) external returns (address) {
        ERC1967Proxy proxy = new ERC1967Proxy(
            implementation,
            data
        );
        return address(proxy);
    }
}
```

## Gouvernance des Upgrades

### Rôles d'Upgrade
```solidity
UPGRADER_ROLE:
- Multisig 3/5 pour contrats critiques (Core, Access)
- Multisig 2/3 pour contrats business (Projects, Social)
- Timelock 48h pour tous upgrades
- Gouvernance communautaire pour changements majeurs
```

### Process d'Upgrade
```
1. Proposition → Governance forum
2. Vote communautaire → 7 jours
3. Audit technique → Sécurité
4. Timelock activation → 48h délai
5. Upgrade exécution → Multisig
6. Vérification → Tests post-upgrade
```

## Tests & Sécurité

### Tests Requis
```bash
# Tests upgrade simulation
forge test --match-contract UpgradeTest

# Tests compatibilité storage
forge test --match-function testStorageCompatibility

# Tests regression complète
forge test --gas-report

# Audit automatisé
slither contracts/src/upgrades/
```

### Storage Layout Protection
```solidity
// V1
struct DataRegistry {
    bytes32 dataHash;        // slot 0
    address owner;           // slot 1
    DataType dataType;       // slot 2
    // NE JAMAIS CHANGER L'ORDRE OU SUPPRIMER
}

// V2 - Seulement ajouts en fin
struct DataRegistry {
    bytes32 dataHash;        // slot 0 - INCHANGÉ
    address owner;           // slot 1 - INCHANGÉ
    DataType dataType;       // slot 2 - INCHANGÉ
    uint256 newField;        // slot 3 - NOUVEAU OK
}
```

## Migration Strategy

### Upgrade Safe
```solidity
// 1. Deploy nouvelle implémentation
LksAccessV2 newImpl = new LksAccessV2();

// 2. Vérifier compatibilité
require(newImpl.VERSION() > currentVersion);

// 3. Upgrade via proxy
upgradeToAndCall(address(newImpl), migrationData);

// 4. Vérification post-upgrade
require(proxy.version() == newImpl.VERSION());
```

### Rollback Plan
```solidity
// Backup de l'ancienne implémentation
address previousImplementation = getCurrentImplementation();

// En cas de problème, rollback immédiat
function emergencyRollback() external onlyRole(DEFAULT_ADMIN_ROLE) {
    upgradeTo(previousImplementation);
}
```

Cette stratégie équilibre **évolutivité** (pour la logique métier) et **immutabilité** (pour la confiance) tout en maintenant la sécurité maximale ! 🛡️