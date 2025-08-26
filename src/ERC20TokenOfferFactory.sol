// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {AccountScoreProvider} from "src/AccountScoreProvider.sol";
import {ERC20TokenOffer} from "src/ERC20TokenOffer.sol";
import {ERC20TokenOfferCycle} from "src/ERC20TokenOfferCycle.sol";

contract ERC20TokenOfferFactory {
    error AccountScoreProviderShouldHaveAdmin();

    function createERC20TokenOffer(
        address accountScoreProviderAdmin,
        address accountScoreProvider,
        address offerOwner,
        address offerToken,
        uint256 tokenPriceInCRC,
        uint256 offerLimitInCRC,
        uint256 offerStart,
        uint256 offerDuration,
        string memory orgName,
        address[] memory acceptedCRC
    ) external returns (address tokenOffer) {
        if (accountScoreProviderAdmin == address(0) && accountScoreProvider == address(0)) {
            revert AccountScoreProviderShouldHaveAdmin();
        }
        if (accountScoreProvider == address(0)) {
            accountScoreProvider = address(new AccountScoreProvider(accountScoreProviderAdmin));
        }
        tokenOffer = address(
            new ERC20TokenOffer(
                offerOwner,
                offerToken,
                accountScoreProvider,
                tokenPriceInCRC,
                offerLimitInCRC,
                offerStart,
                offerDuration,
                orgName,
                acceptedCRC
            )
        );
    }

    function createERC20TokenOfferCycle(
        address admin,
        address offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        string memory offerName,
        string memory cycleName
    ) external returns (address offerCycle) {
        address accountScoreProvider = address(new AccountScoreProvider(admin));
        offerCycle = address(
            new ERC20TokenOfferCycle(
                admin, accountScoreProvider, offerToken, offersStart, offerDuration, offerName, cycleName
            )
        );
    }
}
