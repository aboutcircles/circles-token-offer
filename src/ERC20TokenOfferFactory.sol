// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {AccountWeightProviderUnbounded} from "src/AccountWeightProviderUnbounded.sol";
import {AccountWeightProviderBinary} from "src/AccountWeightProviderBinary.sol";
import {ERC20TokenOffer} from "src/ERC20TokenOffer.sol";
import {ERC20TokenOfferCycle} from "src/ERC20TokenOfferCycle.sol";

contract ERC20TokenOfferFactory {
    error AccountWeightProviderShouldHaveAdmin();
    error InvalidAccountWeightProvider();

    mapping(address => bool) internal createdAccountWeightProvider;

    function createAccountWeightProvider(address admin, bool unbounded) public returns (address provider) {
        if (admin == address(0)) revert AccountWeightProviderShouldHaveAdmin();
        provider = unbounded
            ? address(new AccountWeightProviderUnbounded(admin))
            : address(new AccountWeightProviderBinary(admin));
        createdAccountWeightProvider[provider] = true;
    }

    function createERC20TokenOffer(
        address accountWeightProvider,
        address offerOwner,
        address offerToken,
        uint256 tokenPriceInCRC,
        uint256 offerLimitInCRC,
        uint256 offerStart,
        uint256 offerDuration,
        string memory orgName,
        address[] memory acceptedCRC
    ) external returns (address tokenOffer) {
        if (accountWeightProvider == address(0)) accountWeightProvider = createAccountWeightProvider(offerOwner, true);
        else if (!createdAccountWeightProvider[accountWeightProvider]) revert InvalidAccountWeightProvider();

        tokenOffer = address(
            new ERC20TokenOffer(
                accountWeightProvider,
                offerOwner,
                offerToken,
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
        address accountWeightProvider,
        address cycleOwner,
        address offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        string memory offerName,
        string memory cycleName
    ) external returns (address offerCycle) {
        if (accountWeightProvider == address(0)) accountWeightProvider = createAccountWeightProvider(cycleOwner, true);
        else if (!createdAccountWeightProvider[accountWeightProvider]) revert InvalidAccountWeightProvider();
        offerCycle = address(
            new ERC20TokenOfferCycle(
                accountWeightProvider, cycleOwner, offerToken, offersStart, offerDuration, offerName, cycleName
            )
        );
    }
}
