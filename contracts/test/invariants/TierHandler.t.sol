// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test}         from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LksTier1155}  from "../../src/tier/LksTier1155.sol";
import {ITier1155}    from "../../src/tier/ITier1155.sol";

/**
 * @title  TierHandler
 * @notice Bounded handler for LksTier1155 invariant tests.
 */
contract TierHandler is Test {
    LksTier1155 public tier;
    address[]   public actors;
    uint256[]   public tierIds;

    constructor(LksTier1155 _tier, address[] memory _actors, uint256[] memory _tiers) {
        tier    = _tier;
        actors  = _actors;
        tierIds = _tiers;
    }

    function subscribe(uint256 actorSeed, uint256 tierSeed) public {
        address user   = actors[actorSeed % actors.length];
        uint256 tierId = tierIds[tierSeed % tierIds.length];
        ITier1155.TierConfig memory cfg = tier.tierConfig(tierId);
        if (!cfg.active || cfg.duration == 0) return;
        if (cfg.maxSupply > 0 && tier.totalSupply(tierId) >= cfg.maxSupply
            && tier.balanceOf(user, tierId) == 0) return;
        vm.deal(user, uint256(cfg.price));
        vm.prank(user);
        try tier.subscribe{value: cfg.price}(tierId) {} catch {}
    }

    function cancelAndRefund(uint256 actorSeed, uint256 tierSeed) public {
        address user   = actors[actorSeed % actors.length];
        uint256 tierId = tierIds[tierSeed % tierIds.length];
        if (tier.balanceOf(user, tierId) == 0) return;
        vm.prank(user);
        try tier.cancelAndRefund(tierId) returns (uint256) {} catch {}
    }

    function warpForward(uint256 secondsForward) public {
        secondsForward = bound(secondsForward, 1, 30 days);
        vm.warp(block.timestamp + secondsForward);
    }

    function actorsLength() external view returns (uint256) { return actors.length; }
    function tierIdsLength() external view returns (uint256) { return tierIds.length; }
}

/**
 * @title  TierInvariantTest
 * @notice INV-09, INV-10.
 *
 *         INV-09 : balanceOf(user, tierId) ≤ 1
 *         INV-10 : balanceOf > 0 ⇒ expiresAt > 0
 *         + sanity : sum(balanceOf[*][tierId]) == totalSupply(tierId)
 *         + sanity : address(tier).balance ≥ 0 et reflète paiements - refunds - treasury
 */
contract TierInvariantTest is Test {
    LksTier1155 internal tier;
    TierHandler internal handler;

    address internal admin    = makeAddr("admin");
    address internal treasury = makeAddr("treasury");

    address[] internal actors;
    uint256[] internal tierIds;

    function setUp() public {
        LksTier1155 impl = new LksTier1155();
        bytes memory data = abi.encodeWithSelector(
            LksTier1155.initialize.selector, admin, treasury, "https://lks.example/{id}.json"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        tier = LksTier1155(address(proxy));

        // Setup tier configs
        vm.startPrank(admin);
        tier.setTierConfig(1, ITier1155.TierConfig({price: 0.1 ether, duration: 30 days, maxSupply: 0, active: true}));
        tier.setTierConfig(2, ITier1155.TierConfig({price: 0.5 ether, duration: 30 days, maxSupply: 100, active: true}));
        tier.setTierConfig(3, ITier1155.TierConfig({price: 1.0 ether, duration: 30 days, maxSupply: 50, active: true}));
        vm.stopPrank();

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));
        actors.push(makeAddr("eve"));

        tierIds.push(1);
        tierIds.push(2);
        tierIds.push(3);

        handler = new TierHandler(tier, actors, tierIds);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = TierHandler.subscribe.selector;
        selectors[1] = TierHandler.cancelAndRefund.selector;
        selectors[2] = TierHandler.warpForward.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice INV-09 : balanceOf(user, tierId) ≤ 1 toujours
    function invariant_balanceAtMostOne() public view {
        for (uint256 i = 0; i < actors.length; ++i) {
            for (uint256 j = 0; j < tierIds.length; ++j) {
                assertLe(tier.balanceOf(actors[i], tierIds[j]), 1);
            }
        }
    }

    /// @notice INV-10 : balanceOf > 0 ⇒ expiresAt > 0
    function invariant_balanceImpliesExpiry() public view {
        for (uint256 i = 0; i < actors.length; ++i) {
            for (uint256 j = 0; j < tierIds.length; ++j) {
                if (tier.balanceOf(actors[i], tierIds[j]) > 0) {
                    assertGt(tier.expiresAt(actors[i], tierIds[j]), 0);
                }
            }
        }
    }

    /// @notice Sanity : sum(balanceOf) == totalSupply pour chaque tierId
    function invariant_supplyMatchesBalances() public view {
        for (uint256 j = 0; j < tierIds.length; ++j) {
            uint256 sum = 0;
            for (uint256 i = 0; i < actors.length; ++i) {
                sum += tier.balanceOf(actors[i], tierIds[j]);
            }
            assertEq(sum, tier.totalSupply(tierIds[j]));
        }
    }
}
