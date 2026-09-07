// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test}            from "forge-std/Test.sol";
import {ERC1967Proxy}    from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LksContent1155}  from "../../src/content/LksContent1155.sol";
import {IContent1155}    from "../../src/content/IContent1155.sol";

/**
 * @title  ContentHandler
 * @notice Bounded handler for LksContent1155 invariant tests.
 *         Buyers register content + purchase ; cross-buys exercise mintCount caps.
 */
contract ContentHandler is Test {
    LksContent1155 public content;
    address[]      public actors;
    bytes32[]      public registered; // tokenIds existants

    /// @dev Ghost : sum tracked of all wei sent via purchase.
    uint256 public ghost_totalPurchased;
    uint256 public ghost_creatorWithdrawn;
    uint256 public ghost_platformWithdrawn;

    constructor(LksContent1155 _content, address[] memory _actors) {
        content = _content;
        actors  = _actors;
    }

    function registerContent(uint256 actorSeed, uint256 cidSeed, uint128 price, uint16 royaltyBps, bool soulbound) public {
        address creator = actors[actorSeed % actors.length];
        bytes32 cid     = keccak256(abi.encodePacked(cidSeed, creator));
        price       = uint128(bound(uint256(price), 1e13, 1 ether));
        royaltyBps  = uint16(bound(uint256(royaltyBps), 0, 10_000));

        // Skip si déjà enregistré pour cet user-cid
        uint256 tokenId = content.tokenIdOf(creator, cid);
        if (content.contentMeta(tokenId).creator != address(0)) return;

        vm.prank(creator);
        try content.registerContent(cid, price, 50, royaltyBps, soulbound) returns (uint256) {
            registered.push(bytes32(tokenId));
        } catch {}
    }

    function purchase(uint256 buyerSeed, uint256 tokenSeed) public {
        if (registered.length == 0) return;
        address buyer = actors[buyerSeed % actors.length];
        uint256 tokenId = uint256(registered[tokenSeed % registered.length]);
        IContent1155.ContentMeta memory m = content.contentMeta(tokenId);
        if (m.creator == address(0)) return;
        if (m.maxSupply > 0 && m.mintCount >= m.maxSupply) return;
        if (content.balanceOf(buyer, tokenId) > 0) return;

        vm.deal(buyer, m.price);
        vm.prank(buyer);
        try content.purchase{value: m.price}(tokenId) {
            ghost_totalPurchased += m.price;
        } catch {}
    }

    function withdrawEarnings(uint256 actorSeed) public {
        address creator = actors[actorSeed % actors.length];
        uint256 owed = content.pendingEarnings(creator);
        if (owed == 0) return;
        vm.prank(creator);
        try content.withdrawEarnings() {
            ghost_creatorWithdrawn += owed;
        } catch {}
    }

    function withdrawPlatformFees() public {
        uint256 fees = content.accumulatedPlatformFees();
        if (fees == 0) return;
        try content.withdrawPlatformFees() {
            ghost_platformWithdrawn += fees;
        } catch {}
    }

    function actorsLength() external view returns (uint256) { return actors.length; }
    function registeredLength() external view returns (uint256) { return registered.length; }
}

/**
 * @title  ContentInvariantTest
 * @notice INV-11, INV-12, INV-19.
 *
 *         INV-11 : royaltyBps[tokenId] ≤ 10000
 *         INV-12 : sum(pendingEarnings) + accumulatedPlatformFees == address(content).balance
 *         INV-19 : tokenId existant ⇒ meta.creator != 0
 */
contract ContentInvariantTest is Test {
    LksContent1155  internal content;
    ContentHandler  internal handler;

    address internal admin     = makeAddr("admin");
    address internal treasury  = makeAddr("treasury");
    address internal earnSigner = makeAddr("earnSigner");

    address[] internal actors;

    function setUp() public {
        LksContent1155 impl = new LksContent1155();
        bytes memory data = abi.encodeWithSelector(
            LksContent1155.initialize.selector,
            admin, treasury, earnSigner, uint16(250), ""
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        content = LksContent1155(address(proxy));

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));

        handler = new ContentHandler(content, actors);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ContentHandler.registerContent.selector;
        selectors[1] = ContentHandler.purchase.selector;
        selectors[2] = ContentHandler.withdrawEarnings.selector;
        selectors[3] = ContentHandler.withdrawPlatformFees.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice INV-11 : royaltyBps ≤ 10000 pour tout token enregistré
    function invariant_royaltyBpsBounded() public view {
        for (uint256 i = 0; i < handler.registeredLength(); ++i) {
            uint256 tokenId = uint256(handler.registered(i));
            assertLe(content.contentMeta(tokenId).royaltyBps, uint16(10000));
        }
    }

    /// @notice INV-12 : sum(earnings) + platformFees == contract balance
    function invariant_balanceAccounting() public view {
        uint256 sumEarnings = 0;
        for (uint256 i = 0; i < actors.length; ++i) {
            sumEarnings += content.pendingEarnings(actors[i]);
        }
        uint256 expectedBalance =
            handler.ghost_totalPurchased()
            - handler.ghost_creatorWithdrawn()
            - handler.ghost_platformWithdrawn();

        assertEq(address(content).balance, expectedBalance);
        assertEq(sumEarnings + content.accumulatedPlatformFees(), expectedBalance);
    }

    /// @notice INV-19 : tokenId enregistré ⇒ creator != 0
    function invariant_creatorAlwaysSet() public view {
        for (uint256 i = 0; i < handler.registeredLength(); ++i) {
            uint256 tokenId = uint256(handler.registered(i));
            assertTrue(content.contentMeta(tokenId).creator != address(0));
        }
    }

    /// @notice Sanity : mintCount ≤ maxSupply pour chaque token (sauf maxSupply=0)
    function invariant_mintCountBounded() public view {
        for (uint256 i = 0; i < handler.registeredLength(); ++i) {
            uint256 tokenId = uint256(handler.registered(i));
            IContent1155.ContentMeta memory m = content.contentMeta(tokenId);
            if (m.maxSupply > 0) {
                assertLe(m.mintCount, m.maxSupply);
            }
        }
    }
}
