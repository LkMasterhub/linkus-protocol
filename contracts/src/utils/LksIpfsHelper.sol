// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title LksIpfsHelper
 * @dev Helper pour gérer les références IPFS des assets LinkUs
 * CID racine: QmRWbv1XeGaVwy192N2vZhUd3Cb1WY8EUyAaHZRYBHzz3Z
 */
library LksIpfsHelper {
    // CID racine des assets LinkUs (peut être mis à jour par governance)
    string public constant DEFAULT_IPFS_ROOT = "QmRWbv1XeGaVwy192N2vZhUd3Cb1WY8EUyAaHZRYBHzz3Z";

    // Gateways IPFS supportés
    string public constant GATEWAY_IPFS_IO = "https://ipfs.io/ipfs/";
    string public constant GATEWAY_CLOUDFLARE = "https://cloudflare-ipfs.com/ipfs/";
    string public constant GATEWAY_PINATA = "https://gateway.pinata.cloud/ipfs/";

    // Assets prédéfinis
    string public constant DEFAULT_PROFILE_IMAGE = "img/profile/default.png";
    string public constant ADMIN_PROFILE_IMAGE = "img/profile/admin.png";
    string public constant MANIFEST_PATH = "meta/manifest.json";

    /**
     * @dev Construire l'URL complète d'un asset IPFS
     * @param ipfsRoot CID racine (si empty, utilise DEFAULT_IPFS_ROOT)
     * @param assetPath Chemin vers l'asset (ex: "img/profile/admin.png")
     * @param gateway Gateway IPFS (si empty, utilise GATEWAY_IPFS_IO)
     * @return URL complète de l'asset
     */
    function buildAssetUrl(
        string memory ipfsRoot,
        string memory assetPath,
        string memory gateway
    ) internal pure returns (string memory) {
        string memory root = bytes(ipfsRoot).length > 0 ? ipfsRoot : DEFAULT_IPFS_ROOT;
        string memory gw = bytes(gateway).length > 0 ? gateway : GATEWAY_IPFS_IO;

        return string(abi.encodePacked(gw, root, "/", assetPath));
    }

    /**
     * @dev Construire l'URL d'une image de profil
     * @param filename Nom du fichier (ex: "admin.png")
     * @param ipfsRoot CID racine optionnel
     * @return URL complète de l'image de profil
     */
    function buildProfileImageUrl(
        string memory filename,
        string memory ipfsRoot
    ) internal pure returns (string memory) {
        string memory path = string(abi.encodePacked("img/profile/", filename));
        return buildAssetUrl(ipfsRoot, path, "");
    }

    /**
     * @dev Construire l'URL d'un avatar
     * @param filename Nom du fichier
     * @param ipfsRoot CID racine optionnel
     * @return URL complète de l'avatar
     */
    function buildAvatarUrl(
        string memory filename,
        string memory ipfsRoot
    ) internal pure returns (string memory) {
        string memory path = string(abi.encodePacked("img/avatars/", filename));
        return buildAssetUrl(ipfsRoot, path, "");
    }

    /**
     * @dev Construire l'URL d'une bannière
     * @param filename Nom du fichier
     * @param ipfsRoot CID racine optionnel
     * @return URL complète de la bannière
     */
    function buildBannerUrl(
        string memory filename,
        string memory ipfsRoot
    ) internal pure returns (string memory) {
        string memory path = string(abi.encodePacked("img/banners/", filename));
        return buildAssetUrl(ipfsRoot, path, "");
    }

    /**
     * @dev Construire l'URL d'une icône système
     * @param filename Nom du fichier
     * @param ipfsRoot CID racine optionnel
     * @return URL complète de l'icône
     */
    function buildIconUrl(
        string memory filename,
        string memory ipfsRoot
    ) internal pure returns (string memory) {
        string memory path = string(abi.encodePacked("img/icons/", filename));
        return buildAssetUrl(ipfsRoot, path, "");
    }

    /**
     * @dev Construire l'URL du manifeste
     * @param ipfsRoot CID racine optionnel
     * @return URL complète du manifeste
     */
    function buildManifestUrl(
        string memory ipfsRoot
    ) internal pure returns (string memory) {
        return buildAssetUrl(ipfsRoot, MANIFEST_PATH, "");
    }

    /**
     * @dev Valider qu'un CID IPFS est au bon format
     * @param cid CID à valider
     * @return true si le CID semble valide
     */
    function isValidIpfsCid(string memory cid) internal pure returns (bool) {
        bytes memory cidBytes = bytes(cid);

        // Vérifications basiques
        if (cidBytes.length < 40 || cidBytes.length > 60) {
            return false;
        }

        // Doit commencer par "Qm" (CIDv0) ou "bafy" (CIDv1)
        if (cidBytes.length >= 2) {
            if (cidBytes[0] == 0x51 && cidBytes[1] == 0x6d) { // "Qm"
                return true;
            }
        }

        if (cidBytes.length >= 4) {
            if (cidBytes[0] == 0x62 && cidBytes[1] == 0x61 &&
                cidBytes[2] == 0x66 && cidBytes[3] == 0x79) { // "bafy"
                return true;
            }
        }

        return false;
    }

    /**
     * @dev Extraire le nom de fichier d'un chemin d'asset
     * @param assetPath Chemin complet (ex: "img/profile/admin.png")
     * @return Nom de fichier (ex: "admin.png")
     */
    function extractFilename(string memory assetPath) internal pure returns (string memory) {
        bytes memory pathBytes = bytes(assetPath);
        uint256 lastSlash = 0;

        // Trouver le dernier '/'
        for (uint256 i = pathBytes.length; i > 0; i--) {
            if (pathBytes[i - 1] == 0x2f) { // '/'
                lastSlash = i;
                break;
            }
        }

        if (lastSlash == 0) {
            return assetPath; // Pas de slash trouvé
        }

        // Extraire la partie après le dernier slash
        bytes memory filename = new bytes(pathBytes.length - lastSlash);
        for (uint256 i = 0; i < filename.length; i++) {
            filename[i] = pathBytes[lastSlash + i];
        }

        return string(filename);
    }

    /**
     * @dev Construire l'URL avec un gateway de fallback
     * @param ipfsRoot CID racine
     * @param assetPath Chemin vers l'asset
     * @param primaryGateway Gateway principal
     * @param fallbackGateway Gateway de fallback
     * @return primary URL principale
     * @return fallbackUrl URL de fallback
     */
    function buildAssetUrlWithFallback(
        string memory ipfsRoot,
        string memory assetPath,
        string memory primaryGateway,
        string memory fallbackGateway
    ) internal pure returns (string memory primary, string memory fallbackUrl) {
        primary = buildAssetUrl(ipfsRoot, assetPath, primaryGateway);
        fallbackUrl = buildAssetUrl(ipfsRoot, assetPath, fallbackGateway);
    }
}