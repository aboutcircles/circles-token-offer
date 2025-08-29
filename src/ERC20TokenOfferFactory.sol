// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {AccountWeightProviderUnbounded} from "src/AccountWeightProviderUnbounded.sol";
import {ERC20TokenOffer} from "src/ERC20TokenOffer.sol";
import {ERC20TokenOfferCycle} from "src/ERC20TokenOfferCycle.sol";

/// @title ERC20TokenOfferFactory
/// @notice Factory for creating account weight providers, standalone ERC-20 token offers,
///         and time-based offer cycles. Also signals to offers whether they were created by a cycle.
/// @dev
/// - When a cycle calls `createERC20TokenOffer`, the transient flag `isCreatedByCycle` is set
///   for the duration of the offer’s construction so the offer can read it in its constructor.
/// - Providers created by this factory are marked in `createdAccountWeightProvider`.
/// - Cycles created by this factory are marked in `createdCycle`.
contract ERC20TokenOfferFactory {
    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when creating a provider with a zero admin address.
    error ZeroAdmin();

    /// @notice Thrown when a provided account weight provider is not recognized as factory-created.
    error UnknownProvider();

    /// @notice Thrown when creating offers/cycles with a zero ERC-20 token address.
    error ZeroOfferToken();

    /// @notice Thrown when creating offers with a zero CRC price.
    error ZeroPrice();

    /// @notice Thrown when creating offers with a zero base per-account limit.
    error ZeroLimit();

    /// @notice Thrown when creating offers/cycles with a zero duration.
    error ZeroDuration();

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new account weight provider is created by the factory.
    /// @param provider The new provider address.
    /// @param admin The provider admin address.
    event AccountWeightProviderCreated(address indexed provider, address indexed admin);

    /// @notice Emitted when a standalone ERC20 token offer is created.
    /// @param tokenOffer The newly created offer address.
    /// @param offerOwner The owner/admin of the offer.
    /// @param accountWeightProvider The provider used to gate per-account limits.
    /// @param offerToken The ERC-20 token being sold by the offer.
    /// @param tokenPriceInCRC How many CRC units are required per 1 token unit.
    /// @param offerLimitInCRC Base per-account CRC limit before weighting.
    /// @param offerDuration Duration of the offer, in seconds.
    /// @param orgName Human-readable org/offer name to register in the Hub (used by the offer).
    /// @param acceptedCRC CRC ids (addresses) that the offer trusts/accepts.
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

    /// @notice Emitted when an ERC20 token offer cycle is created.
    /// @param offerCycle The newly created cycle address.
    /// @param cycleOwner The owner/admin of the cycle.
    /// @param offerToken The ERC-20 token to be sold by offers within the cycle.
    /// @param offersStart Start timestamp (inclusive) for the first offer slot.
    /// @param offerDuration Duration (seconds) for each slot in the cycle.
    /// @param offerName Prefix used to compose per-offer names inside the cycle.
    /// @param cycleName Human-readable org name registered in the Hub for the cycle.
    event ERC20TokenOfferCycleCreated(
        address indexed offerCycle,
        address indexed cycleOwner,
        address indexed offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        string offerName,
        string cycleName
    );

    /*//////////////////////////////////////////////////////////////
                                Storage
    //////////////////////////////////////////////////////////////*/

    /// @notice Registry of providers created by this factory.
    mapping(address => bool) public createdAccountWeightProvider;

    /// @notice Registry of cycles created by this factory.
    mapping(address => bool) public createdCycle;

    /// @notice Transient flag set to true for the duration of an offer constructor when called from a cycle.
    /// @dev Read by the `ERC20TokenOffer` constructor via `IERC20TokenOfferFactory(msg.sender).isCreatedByCycle()`.
    bool public transient isCreatedByCycle;

    /*//////////////////////////////////////////////////////////////
                           Provider Creation
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a new (unbounded/graded) account weight provider with a specified admin.
    /// @dev Marks the provider in `createdAccountWeightProvider` and emits {AccountWeightProviderCreated}.
    /// @param admin The admin address to set on the newly created provider.
    /// @return provider The address of the newly created provider.
    function createAccountWeightProvider(address admin) public returns (address provider) {
        if (admin == address(0)) revert ZeroAdmin();
        provider = address(new AccountWeightProviderUnbounded(admin));
        createdAccountWeightProvider[provider] = true;
        emit AccountWeightProviderCreated(provider, admin);
    }

    /*//////////////////////////////////////////////////////////////
                             Offer Creation
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a standalone ERC20 token offer.
    /// @dev
    /// - If `accountWeightProvider == address(0)`, the factory creates a new **unbounded** provider
    ///   with `offerOwner` as admin and uses it.
    /// - If a nonzero `accountWeightProvider` is supplied, it must have been created by this factory; otherwise reverts.
    /// - If the caller is a factory-created cycle, `isCreatedByCycle` is set to true for the offer’s constructor.
    /// @param accountWeightProvider Address of an existing provider or zero to auto-create an unbounded provider.
    /// @param offerOwner Owner/admin of the offer.
    /// @param offerToken ERC-20 token being sold.
    /// @param tokenPriceInCRC CRC units required per 1 token unit (pre-decimals).
    /// @param offerLimitInCRC Base per-account CRC limit before weighting.
    /// @param offerStart Offer start timestamp (inclusive).
    /// @param offerDuration Offer duration in seconds (must be > 0).
    /// @param orgName Human-readable org/offer name to register (used by the offer).
    /// @param acceptedCRC CRC ids (addresses) that the offer trusts/accepts.
    /// @return tokenOffer Address of the newly created offer.
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
        if (offerToken == address(0)) revert ZeroOfferToken();
        if (tokenPriceInCRC == 0) revert ZeroPrice();
        if (offerLimitInCRC == 0) revert ZeroLimit();
        if (offerDuration == 0) revert ZeroDuration();

        // Use existing provider if valid; otherwise create a new unbounded provider with `offerOwner` as admin.
        if (accountWeightProvider == address(0)) {
            accountWeightProvider = createAccountWeightProvider(offerOwner);
        } else if (!createdAccountWeightProvider[accountWeightProvider]) {
            revert UnknownProvider();
        }

        // Signal to the offer if it is being created by a factory-created cycle.
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

        // Reset transient flag after construction.
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

    /*//////////////////////////////////////////////////////////////
                              Cycle Creation
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a new ERC20 token offer cycle with a shared weight provider.
    /// @dev The cycle’s constructor will create its shared provider and register in the Hub.
    /// @param cycleOwner Owner/admin of the cycle.
    /// @param offerToken ERC-20 token to be sold by offers in the cycle.
    /// @param offersStart First offer start timestamp (inclusive).
    /// @param offerDuration Duration (seconds) for each offer slot (must be > 0).
    /// @param enableSoftLock Enable/disable soft-lock checks in the cycle.
    /// @param offerName Prefix used to build per-offer names inside the cycle.
    /// @param cycleName Human-readable org name to register in the Hub for the cycle.
    /// @return offerCycle Address of the newly created cycle.
    function createERC20TokenOfferCycle(
        address cycleOwner,
        address offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        bool enableSoftLock,
        string memory offerName,
        string memory cycleName
    ) external returns (address offerCycle) {
        if (offerToken == address(0)) revert ZeroOfferToken();
        if (offerDuration == 0) revert ZeroDuration();

        offerCycle = address(
            new ERC20TokenOfferCycle(
                cycleOwner, offerToken, offersStart, offerDuration, enableSoftLock, offerName, cycleName
            )
        );

        createdCycle[offerCycle] = true;

        emit ERC20TokenOfferCycleCreated(
            offerCycle, cycleOwner, offerToken, offersStart, offerDuration, offerName, cycleName
        );
    }
}
