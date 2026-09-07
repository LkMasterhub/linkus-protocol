<h1 align="center">LinkUs Protocol</h1>

<p align="center">
  <b>L'infrastructure sociale qui appartient à ses utilisateurs.</b><br>
  Un réseau maillé pair-à-pair qui fonctionne <i>même sans Internet</i> — identité auto-détenue, données chiffrées, gouvernance on-chain.
</p>

<p align="center">
  <a href="https://soliditylang.org/"><img src="https://img.shields.io/badge/Solidity-0.8.20%2F0.8.28-orange" alt="Solidity"></a>
  <a href="https://www.rust-lang.org/"><img src="https://img.shields.io/badge/Rust-1.85-brown" alt="Rust"></a>
  <a href="https://svelte.dev/"><img src="https://img.shields.io/badge/Svelte-5-red" alt="Svelte"></a>
  <a href="#-où-en-est-le-projet"><img src="https://img.shields.io/badge/statut-Sepolia%20testnet%20%C2%B7%20alpha-yellow" alt="Statut"></a>
</p>

---

> 📎 **Ce dépôt est une vitrine publique.** Il contient les **smart contracts**
> (source + tests, identiques au code vérifié sur Etherscan) et une
> documentation d'architecture de haut niveau. Le moteur de nœuds mesh, les
> frontends et certains services applicatifs sont développés dans un dépôt
> privé et ne sont pas republiés ici — voir [Périmètre de ce dépôt](#-périmètre-de-ce-dépôt).

## Le problème

Les réseaux sociaux d'aujourd'hui possèdent vos données, votre identité et votre audience. Un changement d'algorithme, une panne, une censure ou une faillite, et tout disparaît. La « décentralisation » Web3 reste par ailleurs le plus souvent **dépendante d'Internet et de serveurs d'infrastructure** — elle déplace le point de contrôle sans nécessairement le supprimer.

## La proposition

**LinkUs Protocol** est une infrastructure sociale décentralisée où **l'utilisateur redevient propriétaire** de son identité, de ses données et de ses interactions.

Elle sépare proprement les quatre responsabilités qu'un réseau social confond habituellement — **le réseau, le stockage, l'identité et la blockchain** — pour n'en faire dépendre aucune d'un serveur unique. Les contenus circulent via un moteur de nœuds distribués, les identités reposent sur des NFT soulbound et des documents DID, et les contrats intelligents assurent gouvernance, abonnements, transactions et réputation.

## Ce qui nous rend différents

- 🛰️ **Offline-first au niveau du nœud.** Le cœur du projet fait transiter les données par n'importe quel médium disponible : Wi-Fi local, WebRTC, Bluetooth ou LoRa, de nœud à nœud. Un nœud n'a besoin d'aucune connexion Internet pour participer au réseau — le relai se fait de proche en proche ; la blockchain n'intervient que pour les actions à enjeu (identité, paiements, votes), de façon asynchrone dès qu'une passerelle redevient disponible. (Le moteur lui-même n'est pas publié dans ce dépôt, voir plus bas.)
- 🔑 **Autonomie par défaut.** Chiffrement de bout en bout, signature à la source, identité non-transférable détenue par l'utilisateur. Aucune confiance accordée à un relais.
- 🧩 **Une infrastructure, pas une app.** LinkUs n'est pas *un* réseau social de plus : c'est un **substrat ouvert** sur lequel développeurs, communautés et entreprises construisent leurs propres applications décentralisées — sociales, collaboratives, marketplaces, financement participatif — sur une base commune et interopérable.
- ⛓️ **Le meilleur des deux mondes.** Modèle hybride P2P ↔ blockchain : la rapidité et la gratuité du pair-à-pair pour le quotidien, la sécurité de la chaîne pour ce qui compte (identité, paiements, votes).

### Les piliers du protocole

| Pilier | Contenu |
|---|---|
| 🔐 **Identité décentralisée** | NFT Soulbound (ERC-5192), documents DID, récupération d'identité, gestion des droits |
| 🔒 **Communication sécurisée** | Échanges chiffrés de bout en bout, stockage distribué, signature à la source |
| 🗳️ **Gouvernance communautaire** | DAO on-chain, propositions, votes, exécution via Timelock |
| 💰 **Économie intégrée** | Token de gouvernance, staking, abonnements, financement participatif, tips |
| 🧩 **Architecture modulaire** | Chaque composant évolue indépendamment et peut être réutilisé par d'autres applications |

---

## 🚦 Où en est le projet ?

Ce n'est pas un livre blanc : **le protocole tourne déjà**. Un moteur de nœuds Rust fonctionnel (privé), une suite de contrats déployée et vérifiée sur testnet (publiée ici), des frontends fonctionnels (privés). Le projet est en **alpha sur Sepolia** — nous jouons franc-jeu sur ce qui est livré et ce qui reste à faire.

### ✅ Ce qui fonctionne aujourd'hui

- **Moteur de nœuds mesh** — Rust, transport Wi-Fi/WebRTC fonctionnel, BLE et LoRa en cours de câblage matériel. *(dépôt privé)*
- **Contrats déployés & vérifiés sur Sepolia** — suite V8 (identité, core, contenus, business) + socle V7 (token, staking, gouvernance, timelock). Code source dans [`contracts/`](contracts). Voir [adresses](contracts/README.md#contrats-déployés-sepolia).
- **Frontends** — une version en production (SvelteKit SSR) et une version alpha avec nœud navigateur WASM. *(dépôts privés)*

### 🔜 En cours / sur la feuille de route

- **Transports mesh matériels** — BLE et LoRa implémentés côté logiciel, câblage réel sur Raspberry Pi / ESP32 en cours.
- **Firmware embarqué** — cibles microcontrôleur en tant que relais passifs.
- **Plateforme multi-apps** — SDK d'hébergement d'applications tierces (le protocole comme *substrat*).
- **Audit de sécurité externe**, puis **déploiement mainnet**.

> ⚠️ **Testnet, non audité.** Les contrats sont *vérifiés* sur Etherscan (code source public et lisible) mais **n'ont pas encore fait l'objet d'un audit de sécurité externe**. Ne pas utiliser avec des fonds réels.

---

## 🔍 Périmètre de ce dépôt

LinkUs Protocol est développé à travers plusieurs couches ; toutes ne sont pas
republiées ici, pour deux raisons : certaines constituent le cœur technique
différenciant du projet, et certaines contiennent des services applicatifs
qu'on préfère ne pas exposer prêts-à-dupliquer.

| Couche | Dans ce dépôt ? |
|---|---|
| **Smart contracts** (Solidity, Foundry) | ✅ [`contracts/`](contracts) — identique au code vérifié sur Etherscan |
| **Documentation d'architecture** (gouvernance, upgrade, tests, audits de bytecode) | ✅ [`docs/`](docs) |
| **Moteur de nœuds mesh** (Rust, transports BLE/LoRa/Wi-Fi/WebRTC, sync CRDT) | ❌ dépôt privé |
| **Frontends** (SvelteKit) | ❌ dépôt privé |
| **Firmware embarqué** | ❌ dépôt privé |

Cette séparation peut évoluer : à mesure que des composants se stabilisent, il
est possible que davantage de code soit republié ici.

---

## 📦 Contrats déployés (Sepolia)

Voir le détail complet dans [`contracts/README.md`](contracts/README.md#contrats-déployés-sepolia).

| Contrat | Adresse |
|---|---|
| `LksCoreV8` | [`0xE3cf...83a85`](https://sepolia.etherscan.io/address/0xE3cf3ED52b3d889d2f3ED4C8D40E46Ee31483a85) |
| `LksIdentityV2` | [`0xF8B3...F933`](https://sepolia.etherscan.io/address/0xF8B31321Cd8649A76efBBd4B364795F51ea9F933) |
| `LKST` | [`0x508E...dF22`](https://sepolia.etherscan.io/address/0x508E94C06526E040cb66D78dd404CD16a45fdF22) |
| `LKSV` | [`0x15E4...aBf3`](https://sepolia.etherscan.io/address/0x15E4F931C46797c72A268887A1b103E565ECaBf3) |
| `LksGovernance` | [`0xB936...29dc`](https://sepolia.etherscan.io/address/0xB9368210A6ec657FEBaab759467aDe5ce0cE29dc) |

---

## 🚀 Démarrage rapide

```bash
cd contracts
forge install
forge build --via-ir
forge test
```

Prérequis : [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`, `anvil`).

---

## 🧪 Tests

| Couche | Commande |
|---|---|
| Solidity | `cd contracts && forge test` |

---

## 🗺️ Feuille de route

| Phase | Objectif |
|---|---|
| PWA + refonte frontend sur contrats V8 | 2026 |
| Alpha publique | 2026 |
| Audit externe → déploiement mainnet | 2026 |
| Au-delà | Transports matériels (BLE/LoRa), SDK multi-apps, multi-chain |

---

## 🛠️ Technologies (contrats)

Solidity 0.8.20 / 0.8.28, Foundry, OpenZeppelin (Governor, ERC4626, ERC-1155, UUPS).

---

## 📄 Licence

Voir [`LICENSE`](LICENSE). **Tous droits réservés** — ce code est publié pour
la transparence (vérification, audit, lecture) et non sous licence open
source permettant la réutilisation, la redistribution ou la création
d'œuvres dérivées. Contactez-nous si vous souhaitez discuter d'un usage
spécifique.

## 🔗 Liens

- **Site** : [link-us.fr](https://link-us.fr) *(à venir)*

---

*Privacy-first · Décentralisé · Propriété des données par l'utilisateur*
