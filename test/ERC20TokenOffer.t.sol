// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {ERC20TokenOfferFactory} from "src/ERC20TokenOfferFactory.sol";
import {ERC20TokenOfferCycle} from "src/ERC20TokenOfferCycle.sol";
import {ERC20TokenOffer} from "src/ERC20TokenOffer.sol";

contract ERC20TokenOfferTest is Test {
    uint256 gnosisFork;
    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

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

    function setUp() public {
        // Fork from Gnosis
        gnosisFork = vm.createFork(vm.envString("GNOSIS_RPC"));
        vm.selectFork(gnosisFork);
        deal(offerToken, cycleOwner, 1 ether);
        offersStart = block.timestamp + 1 days;

        factory = new ERC20TokenOfferFactory();
        cycle = ERC20TokenOfferCycle(factory.createERC20TokenOfferCycle(cycleOwner, offerToken, offersStart, offerDuration, enableSoftLock, offerName, cycleName));

        // make owner approve cycle to spend all gno
        vm.prank(cycleOwner);
        IERC20(offerToken).approve(address(cycle), type(uint256).max);
    }

    function test_CreateNextOffer() public {
        uint256 tokenPriceInCRC = 10400 ether;
        uint256 offerLimitInCRC = 250 ether;
        address[] memory acceptedCRC = new address[](2);
        acceptedCRC[0] = address(0x1ACA75e38263c79d9D4F10dF0635cc6FCfe6F026); // backers
        acceptedCRC[1] = address(0x86533d1aDA8Ffbe7b6F7244F9A1b707f7f3e239b); // core

        // first create next offer
        vm.prank(cycleOwner);
        offer = ERC20TokenOffer(cycle.createNextOffer(tokenPriceInCRC, offerLimitInCRC, acceptedCRC));

        address[] memory accounts = new address[](3);
        accounts[0] = address(0x2Df5768b313316191Ba36D95071588b069Bfa964);
        accounts[1] = address(0x758731861111728c9dBe70f7854282CF0180C63e);
        accounts[2] = address(0x4817Bc46B628310aE234A1B2DC53B196b07c54B5);

        uint256[] memory weights = new uint256[](3);
        weights[0] = 5000;
        weights[1] = 10000;
        weights[2] = 20000;

        // second write eligible accounts weights
        vm.prank(cycleOwner);
        cycle.setNextOfferAccountWeights(accounts, weights);

        // third deposit tokens
        vm.prank(cycleOwner);
        cycle.depositNextOfferTokens();

        // move in time
        vm.warp(offersStart + 1);
        
        // last sync cycle/offer trust
        cycle.syncOfferTrust();
    }
}
