// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {ERC20TokenOffer} from "src/ERC20TokenOffer.sol";

contract ERC20TokenOfferScript is Script {
    ERC20TokenOffer public offer;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        //offer = new ERC20TokenOffer();

        vm.stopBroadcast();
    }
}
