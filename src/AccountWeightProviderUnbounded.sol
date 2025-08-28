// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IAccountWeightProvider} from "src/interfaces/IAccountWeightProvider.sol";

/// @title AccountWeightProviderUnbounded
/// @notice Provides graded (unbounded) eligibility weights for an offer.
/// @dev Weights are measured in units of getWeightScale() and MAY exceed it.
///      Invariant: weight >= 0 for all accounts.
///      Total weight is the sum of all per-account weights (no cap).
contract AccountWeightProviderUnbounded is IAccountWeightProvider {
    struct OfferWeights {
        uint256 totalAccounts; // count of accounts with a nonzero weight (useful for Binary)
        uint256 totalWeight; // sum of all weights
        bool finalized; // writes locked
        mapping(address => uint256) weightOf; // per-account weight
    }

    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function is called by a non-admin address.
    error OnlyAdmin();
    error ArrayLengthMismatch();
    error WeightsAlreadyFinalized();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    event AccountWeightSet(address indexed offer, address indexed account, uint256 indexed weight);

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant ONE_IN_BASIS_POINTS = 10_000;
    address public immutable ADMIN;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    mapping(address offer => OfferWeights) public offers;

    constructor(address admin) {
        ADMIN = admin;
    }

    function setAccountWeights(address offer, address[] memory accounts, uint256[] memory weights) external {
        OfferWeights storage offerWeights = offers[offer];
        if (msg.sender != ADMIN) revert OnlyAdmin();
        if (accounts.length != weights.length) revert ArrayLengthMismatch();
        if (offerWeights.finalized) revert WeightsAlreadyFinalized();

        uint256 weightsCount;
        uint256 accountsCount;

        for (uint256 i; i < accounts.length;) {
            uint256 accountWeight = offerWeights.weightOf[accounts[i]];

            if (accountWeight != 0) offerWeights.totalWeight -= accountWeight;
            if (accountWeight != 0 && weights[i] == 0) --offerWeights.totalAccounts;
            if (accountWeight == 0 && weights[i] != 0) ++accountsCount;

            offerWeights.weightOf[accounts[i]] = weights[i];
            weightsCount += weights[i];

            emit AccountWeightSet(offer, accounts[i], weights[i]);

            unchecked {
                ++i;
            }
        }
        offerWeights.totalWeight += weightsCount;
        offerWeights.totalAccounts += accountsCount;
    }

    function finalizeWeights() external {
        offers[msg.sender].finalized = true;
        uint256 accountsCount = offers[msg.sender].totalAccounts;
        if (accountsCount > 0) emit WeightsFinalized(msg.sender, accountsCount, offers[msg.sender].totalWeight);
    }

    function getWeightScale() external pure returns (uint256) {
        return ONE_IN_BASIS_POINTS;
    }

    function getAccountWeight(address account) external view returns (uint256) {
        return getAccountWeight(msg.sender, account);
    }

    function getTotalWeight() external view returns (uint256) {
        return offers[msg.sender].totalWeight;
    }

    function getTotalAccounts() external view returns (uint256) {
        return offers[msg.sender].totalAccounts;
    }

    function getAccountWeight(address offer, address account) public view returns (uint256) {
        return offers[offer].weightOf[account];
    }
}
