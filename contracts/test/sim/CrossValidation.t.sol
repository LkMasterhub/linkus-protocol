// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test}      from "forge-std/Test.sol";
import {LksTipSim} from "./LksTipSim.sol";
import {LksFeeSim} from "./LksFeeSim.sol";

/// @title  CrossValidationTest — Phase 3.6 V8
/// @notice Charge le fichier de fixtures partagé avec le crate Rust `lks-sim`
///         (`lks-core/crates/sim/lks-sim/fixtures/tip_split_v1.json`) et
///         vérifie que `LksTipSim.split()` produit byte-pour-byte les mêmes
///         (authorShare, platformFee) que la version Rust.
///
///         Le fichier JSON est généré déterministiquement par le crate Rust
///         (seed 0xC0FFEE, 100 fixtures). Toute divergence indique un drift
///         entre les deux implémentations canoniques (Solidity = on-chain,
///         Rust = off-chain via WASM/lksd).
contract CrossValidationTest is Test {
    /// @dev Symlink vers `lks-core/crates/sim/lks-sim/fixtures/tip_split_v1.json`.
    ///      Le source canonique du fichier vit dans le crate Rust ; le symlink
    ///      permet à Foundry de respecter `fs_permissions` (path relatif au repo).
    string constant FIXTURES_PATH = "test/sim/fixtures/tip_split_v1.json";

    struct Fixture {
        uint256 amount;
        uint16  feeBps;
        uint256 expectedAuthor;
        uint256 expectedFee;
    }

    function _loadFixtures() internal view returns (Fixture[] memory) {
        string memory raw = vm.readFile(FIXTURES_PATH);
        // Le JSON est un array d'objets {amount, fee_bps, expected_author, expected_fee}
        // tous serialisés en strings décimales (precision U256).
        bytes memory amountsRaw  = vm.parseJson(raw, "[*].amount");
        bytes memory feeBpsRaw   = vm.parseJson(raw, "[*].fee_bps");
        bytes memory authorsRaw  = vm.parseJson(raw, "[*].expected_author");
        bytes memory feesRaw     = vm.parseJson(raw, "[*].expected_fee");

        string[] memory amounts = abi.decode(amountsRaw, (string[]));
        uint256[] memory feeBpsList = abi.decode(feeBpsRaw, (uint256[]));
        string[] memory authors = abi.decode(authorsRaw, (string[]));
        string[] memory fees    = abi.decode(feesRaw, (string[]));

        require(amounts.length == feeBpsList.length, "len mismatch amount/bps");
        require(amounts.length == authors.length, "len mismatch amount/author");
        require(amounts.length == fees.length, "len mismatch amount/fee");

        Fixture[] memory out = new Fixture[](amounts.length);
        for (uint256 i; i < amounts.length; ++i) {
            out[i] = Fixture({
                amount:         vm.parseUint(amounts[i]),
                feeBps:         uint16(feeBpsList[i]),
                expectedAuthor: vm.parseUint(authors[i]),
                expectedFee:    vm.parseUint(fees[i])
            });
        }
        return out;
    }

    /// @notice CROSS-01 : `LksTipSim.split` matche bit-pour-bit la version Rust
    ///         sur 100 fixtures déterministes (seed 0xC0FFEE). Diff ≤ 0 wei.
    function test_TipSim_matchesRustImplementation() public view {
        Fixture[] memory fixtures = _loadFixtures();
        assertEq(fixtures.length, 100, "expected 100 fixtures");

        for (uint256 i; i < fixtures.length; ++i) {
            (uint256 author, uint256 fee) = LksTipSim.split(
                fixtures[i].amount,
                fixtures[i].feeBps
            );
            assertEq(author, fixtures[i].expectedAuthor, "author mismatch");
            assertEq(fee,    fixtures[i].expectedFee,    "fee mismatch");
            // Conservation : split sans perte
            assertEq(author + fee, fixtures[i].amount, "wei loss");
        }
    }

    /// @notice CROSS-02 : `LksFeeSim.feeSplit` cohérent avec `LksTipSim.split`
    ///         (même formule, deux noms — vérifier qu'ils ne divergent jamais).
    function test_FeeSim_matchesTipSim() public view {
        Fixture[] memory fixtures = _loadFixtures();
        for (uint256 i; i < fixtures.length; ++i) {
            (uint256 tipAuthor, uint256 tipFee) =
                LksTipSim.split(fixtures[i].amount, fixtures[i].feeBps);
            (uint256 feeMain, uint256 feePlat) =
                LksFeeSim.feeSplit(fixtures[i].amount, fixtures[i].feeBps);
            assertEq(tipAuthor, feeMain, "tip vs fee main divergence");
            assertEq(tipFee,    feePlat, "tip vs fee plat divergence");
        }
    }

    /// @notice CROSS-03 : Sanity — fixtures.length == 100 et chaque fee_bps ≤ 10000.
    function test_Fixtures_areWellFormed() public view {
        Fixture[] memory fixtures = _loadFixtures();
        assertEq(fixtures.length, 100, "fixture count");
        for (uint256 i; i < fixtures.length; ++i) {
            assertLe(fixtures[i].feeBps, 10_000, "feeBps out of range");
            assertGt(fixtures[i].amount, 0, "amount must be > 0");
        }
    }
}
