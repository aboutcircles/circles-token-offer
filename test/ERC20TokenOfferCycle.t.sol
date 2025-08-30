// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HubStorageWrites} from "test/helpers/HubStorageWrites.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {ERC20TokenOfferFactory} from "src/ERC20TokenOfferFactory.sol";
import {ERC20TokenOfferCycle} from "src/ERC20TokenOfferCycle.sol";
import {ERC20TokenOffer} from "src/ERC20TokenOffer.sol";

contract ERC20TokenOfferCycleTest is Test, HubStorageWrites {
    uint256 gnosisFork;
    address cycleOwner = address(0x6d2014AEc52D7969Eb0074f0213e1A831270142C);
    address offerToken = address(0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb);
    uint256 offersStart;
    uint256 offerDuration = 1 weeks;
    bool enableSoftLock = true;
    string offerName = "CRC-GNO offer week";
    string cycleName = "CRC-GNO premium offer cycle";

    ERC20TokenOfferFactory public factory;
    ERC20TokenOfferCycle public cycle;
    ERC20TokenOffer public offer;

    // Test values
    // users
    address[] testAccounts = [
        address(0x2Df5768b313316191Ba36D95071588b069Bfa964),
        address(0x758731861111728c9dBe70f7854282CF0180C63e),
        address(0x4817Bc46B628310aE234A1B2DC53B196b07c54B5)
    ];
    // accepted crc
    address backerCRC = address(0x1ACA75e38263c79d9D4F10dF0635cc6FCfe6F026);
    address coreCRC = address(0x86533d1aDA8Ffbe7b6F7244F9A1b707f7f3e239b);

    function setUp() public {
        // Fork from Gnosis
        gnosisFork = vm.createFork(vm.envString("GNOSIS_RPC"));
        vm.selectFork(gnosisFork);
        // fund owner with 1 GNO
        deal(offerToken, cycleOwner, 1 ether);
        // make from test addresses circles users and fund with accepted crc balances
        uint64 day = IHub(HUB).day(block.timestamp);
        for (uint256 i; i < testAccounts.length; i++) {
            _registerHuman(testAccounts[i]);
            _setCRCBalance(uint256(uint160(backerCRC)), testAccounts[i], day, 2000 ether);
            _setCRCBalance(uint256(uint160(coreCRC)), testAccounts[i], day, 2000 ether);
        }

        offersStart = block.timestamp + 1 days;
        factory = new ERC20TokenOfferFactory();
        cycle = ERC20TokenOfferCycle(
            factory.createERC20TokenOfferCycle(
                cycleOwner, offerToken, offersStart, offerDuration, enableSoftLock, offerName, cycleName
            )
        );

        // make owner approve cycle to spend all gno
        vm.prank(cycleOwner);
        IERC20(offerToken).approve(address(cycle), type(uint256).max);
    }

    function test_CreateNextOffer() public {
        uint256 tokenPriceInCRC = 10400 ether;
        uint256 offerLimitInCRC = 250 ether;
        address[] memory acceptedCRC = new address[](2);
        acceptedCRC[0] = backerCRC;
        acceptedCRC[1] = coreCRC;

        // first create next offer
        vm.prank(cycleOwner);
        offer = ERC20TokenOffer(cycle.createNextOffer(tokenPriceInCRC, offerLimitInCRC, acceptedCRC));

        uint256[] memory weights = new uint256[](3);
        weights[0] = 5000;
        weights[1] = 10000;
        weights[2] = 28000;

        // second write eligible accounts weights
        vm.prank(cycleOwner);
        cycle.setNextOfferAccountWeights(testAccounts, weights);

        // third deposit tokens
        vm.prank(cycleOwner);
        cycle.depositNextOfferTokens();

        // move in time
        vm.warp(offersStart + 1);

        // last sync cycle/offer trust
        cycle.syncOfferTrust();

        // 2 users claims full package, 1 missed to claim
        vm.prank(testAccounts[0]);
        IHub(HUB).safeTransferFrom(testAccounts[0], address(cycle), uint256(uint160(backerCRC)), 125 ether, "");
        uint256[] memory ids = new uint256[](2);
        ids[0] = uint256(uint160(backerCRC));
        ids[1] = uint256(uint160(coreCRC));
        uint256[] memory values = new uint256[](2);
        values[0] = 500 ether;
        values[1] = 200 ether;
        vm.prank(testAccounts[2]);
        IHub(HUB).safeBatchTransferFrom(testAccounts[2], address(cycle), ids, values, "");

        uint256 offerEnd = offer.OFFER_END();

        // create next offer
        tokenPriceInCRC = 9400 ether;
        offerLimitInCRC = 500 ether;
        acceptedCRC = new address[](1);
        acceptedCRC[0] = backerCRC;
        vm.prank(cycleOwner);
        offer = ERC20TokenOffer(cycle.createNextOffer(tokenPriceInCRC, offerLimitInCRC, acceptedCRC));

        // write eligible accounts
        address[] memory accounts = new address[](2);
        accounts[0] = testAccounts[0];
        accounts[1] = testAccounts[1];
        weights = new uint256[](2);
        weights[0] = 15000;
        weights[1] = 10000;

        // second write eligible accounts weights
        vm.prank(cycleOwner);
        cycle.setNextOfferAccountWeights(accounts, weights);

        // third deposit tokens
        vm.prank(cycleOwner);
        cycle.depositNextOfferTokens();

        // move in time
        vm.warp(offerEnd + 1);

        vm.prank(cycleOwner);
        cycle.withdrawUnclaimedOfferTokens(1);

        cycle.isOfferAvailable();

        vm.expectRevert(); // invalid id
        vm.prank(testAccounts[1]);
        IHub(HUB).safeBatchTransferFrom(testAccounts[1], address(cycle), ids, values, "");

        vm.prank(testAccounts[1]);
        IHub(HUB).safeTransferFrom(testAccounts[1], address(cycle), uint256(uint160(backerCRC)), 250 ether, "");
        uint256 balance = IERC20(offerToken).balanceOf(testAccounts[1]);
        vm.prank(testAccounts[1]);
        IERC20(offerToken).transfer(testAccounts[2], balance / 10);

        vm.expectRevert(); // soft lock
        vm.prank(testAccounts[1]);
        IHub(HUB).safeTransferFrom(testAccounts[1], address(cycle), uint256(uint160(backerCRC)), 250 ether, "");

        vm.prank(testAccounts[2]);
        IERC20(offerToken).transfer(testAccounts[1], balance / 10);

        vm.prank(testAccounts[1]);
        IHub(HUB).safeTransferFrom(testAccounts[1], address(cycle), uint256(uint160(backerCRC)), 250 ether, "");

        vm.expectRevert(); // ineligible
        vm.prank(testAccounts[2]);
        IHub(HUB).safeTransferFrom(testAccounts[2], address(cycle), uint256(uint160(backerCRC)), 250 ether, "");

        cycle.getTotalEligibleAccounts();
    }
}
