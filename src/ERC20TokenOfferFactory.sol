// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {AccountWeightProviderUnbounded} from "src/AccountWeightProviderUnbounded.sol";
import {AccountWeightProviderBinary} from "src/AccountWeightProviderBinary.sol";
import {ERC20TokenOffer} from "src/ERC20TokenOffer.sol";
import {ERC20TokenOfferCycle} from "src/ERC20TokenOfferCycle.sol";

contract ERC20TokenOfferFactory {
    error AccountWeightProviderShouldHaveAdmin();
    error InvalidAccountWeightProvider();

    event ERC20TokenOfferCreated(
        address indexed tokenOffer,
        address indexed offerOwner,
        address indexed accountWeightProvider,
        address offerToken,
        uint256 tokenPriceInCRC,
        uint256 offerLimitInCRC,
        uint256 offerDuration,
        string orgName,
        address[] acceptedCRC
    );

    event ERC20TokenOfferCycleCreated(
        address indexed offerCycle,
        address indexed cycleOwner,
        address indexed offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        bool accountWeightProviderUnbounded,
        string offerName,
        string cycleName
    );

    mapping(address => bool) internal createdAccountWeightProvider;
    mapping(address => bool) internal createdCycle;
    bool public transient isCreatedByCycle;

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
        if (createdCycle[msg.sender]) isCreatedByCycle = true;

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

        isCreatedByCycle = false;
        emit ERC20TokenOfferCreated(
            tokenOffer,
            offerOwner,
            accountWeightProvider,
            offerToken,
            tokenPriceInCRC,
            offerLimitInCRC,
            offerDuration,
            orgName,
            acceptedCRC
        );
    }

    function createERC20TokenOfferCycle(
        bool accountWeightProviderUnbounded,
        address cycleOwner,
        address offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        bool enableSoftLock,
        string memory offerName,
        string memory cycleName
    ) external returns (address offerCycle) {
        offerCycle = address(
            new ERC20TokenOfferCycle(
                accountWeightProviderUnbounded,
                cycleOwner,
                offerToken,
                offersStart,
                offerDuration,
                enableSoftLock,
                offerName,
                cycleName
            )
        );
        createdCycle[offerCycle] = true;
        emit ERC20TokenOfferCycleCreated(
            offerCycle,
            cycleOwner,
            offerToken,
            offersStart,
            offerDuration,
            accountWeightProviderUnbounded,
            offerName,
            cycleName
        );
    }
}
