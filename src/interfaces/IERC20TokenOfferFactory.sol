// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface IERC20TokenOfferFactory {
    error UnknownProvider();
    error ZeroAdmin();
    error ZeroDuration();
    error ZeroLimit();
    error ZeroOfferToken();
    error ZeroPrice();

    event AccountWeightProviderCreated(address indexed provider, address indexed admin);
    event ERC20TokenOfferCreated(
        address indexed tokenOffer,
        address indexed offerOwner,
        address indexed accountWeightProvider,
        address offerToken,
        uint256 tokenPriceInCRC,
        uint256 offerLimitInCRC,
        uint256 offerStart,
        uint256 offerEnd,
        string orgName,
        address[] acceptedCRC
    );
    event ERC20TokenOfferCycleCreated(
        address indexed offerCycle,
        address indexed cycleOwner,
        address indexed offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        string offerName,
        string cycleName
    );

    function createAccountWeightProvider(address admin) external returns (address provider);
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
        address cycleOwner,
        address offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        bool enableSoftLock,
        string memory offerName,
        string memory cycleName
    ) external returns (address offerCycle);
    function createdAccountWeightProvider(address) external view returns (bool);
    function createdCycle(address) external view returns (bool);
    function isCreatedByCycle() external view returns (bool);
}
