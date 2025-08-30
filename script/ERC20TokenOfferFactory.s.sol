// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {ERC20TokenOfferFactory} from "src/ERC20TokenOfferFactory.sol";

contract ERC20TokenOfferFactoryScript is Script {
    address deployer = address(0xe327d2059aD7cAA7D4B0d33C410aF1588a03FABf);
    ERC20TokenOfferFactory public factory; // 0x43C8e7cb2fea3A55B52867bb521EBf8cb072fECa

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        factory = new ERC20TokenOfferFactory();

        vm.stopBroadcast();
    }
}
