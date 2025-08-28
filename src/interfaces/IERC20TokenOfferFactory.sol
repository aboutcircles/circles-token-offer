// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface IERC20TokenOfferFactory {
    error AccountWeightProviderShouldHaveAdmin();
    error InvalidAccountWeightProvider();

    function createAccountWeightProvider(address admin, bool unbounded) external returns (address provider);
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
    ) external returns (address tokenOffer);
    function createERC20TokenOfferCycle(
        address accountWeightProvider,
        address cycleOwner,
        address offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        bool enableSoftLock,
        string memory offerName,
        string memory cycleName
    ) external returns (address offerCycle);
    function isCreatedByCycle() external view returns (bool);
}
