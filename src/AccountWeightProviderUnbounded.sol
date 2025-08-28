// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IAccountWeightProvider} from "src/interfaces/IAccountWeightProvider.sol";

/// @title AccountWeightProviderUnbounded
/// @notice Provides graded, unbounded eligibility weights per-offer.
/// @dev
/// - Weights are integers measured in units of `getWeightScale()`.
/// - Invariant: all account weights are non-negative (`>= 0`).
/// - Total weight is the simple sum of all per-account weights, with no maximum cap.
/// - Implements `IAccountWeightProvider`.
contract AccountWeightProviderUnbounded is IAccountWeightProvider {
    /*//////////////////////////////////////////////////////////////
                             Structs
    //////////////////////////////////////////////////////////////*/

    /// @notice Stores per-offer weight data and accounting.
    /// @param totalAccounts Number of accounts with a nonzero weight.
    /// @param totalWeight Sum of all weights across accounts.
    /// @param finalized Whether weights for this offer have been finalized (writes locked).
    /// @param weightOf Mapping of account => assigned weight.
    struct OfferWeights {
        uint256 totalAccounts;
        uint256 totalWeight;
        bool finalized;
        mapping(address => uint256) weightOf;
    }

    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller is not the admin.
    error OnlyAdmin();

    /// @notice Thrown when `accounts` and `weights` input arrays do not match in length.
    error ArrayLengthMismatch();

    /// @notice Thrown when attempting to modify weights after they have been finalized.
    error WeightsAlreadyFinalized();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a specific account weight is set or updated.
    /// @param offer The offer whose weights are being modified.
    /// @param account The account whose weight was set.
    /// @param weight The new weight assigned to the account.
    event AccountWeightSet(address indexed offer, address indexed account, uint256 indexed weight);

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice Weight scale, expressed in basis points (1e4 = 100%).
    uint256 internal constant ONE_IN_BASIS_POINTS = 10_000;

    /// @notice The single admin allowed to set weights.
    address public immutable ADMIN;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping of offer => weight data.
    mapping(address offer => OfferWeights) public offers;

    /*//////////////////////////////////////////////////////////////
                           Constructor
    //////////////////////////////////////////////////////////////*/

    /// @param admin The address authorized to set and finalize weights.
    constructor(address admin) {
        ADMIN = admin;
    }

    /*//////////////////////////////////////////////////////////////
                        Admin/Offer Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets or updates account weights for a given offer.
    /// @dev
    /// - Can only be called by `ADMIN`.
    /// - Reverts if arrays differ in length or if weights are finalized.
    /// - Updates total weight and total accounts counters.
    /// @param offer The offer whose account weights are being set.
    /// @param accounts The list of accounts to set weights for.
    /// @param weights The corresponding weights to assign each account.
    function setAccountWeights(address offer, address[] memory accounts, uint256[] memory weights) external {
        OfferWeights storage offerWeights = offers[offer];
        if (msg.sender != ADMIN) revert OnlyAdmin();
        if (accounts.length != weights.length) revert ArrayLengthMismatch();
        if (offerWeights.finalized) revert WeightsAlreadyFinalized();

        uint256 weightsCount;
        uint256 accountsCount;

        for (uint256 i; i < accounts.length;) {
            uint256 accountWeight = offerWeights.weightOf[accounts[i]];

            // Adjust totals for replacing weights
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

    /// @notice Finalizes weights for the calling offer, preventing further modifications.
    /// @dev Emits {WeightsFinalized} if the offer has at least one account with nonzero weight.
    function finalizeWeights() external {
        offers[msg.sender].finalized = true;
        uint256 accountsCount = offers[msg.sender].totalAccounts;
        if (accountsCount > 0) emit WeightsFinalized(msg.sender, accountsCount, offers[msg.sender].totalWeight);
    }

    /*//////////////////////////////////////////////////////////////
                         View Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAccountWeightProvider
    function getWeightScale() external pure returns (uint256) {
        return ONE_IN_BASIS_POINTS;
    }

    /// @inheritdoc IAccountWeightProvider
    function getAccountWeight(address account) external view returns (uint256) {
        return getAccountWeight(msg.sender, account);
    }

    /// @inheritdoc IAccountWeightProvider
    function getTotalWeight() external view returns (uint256) {
        return offers[msg.sender].totalWeight;
    }

    /// @inheritdoc IAccountWeightProvider
    function getTotalAccounts() external view returns (uint256) {
        return offers[msg.sender].totalAccounts;
    }

    /// @notice Returns the weight of a given account for a specified offer.
    /// @param offer The offer to query.
    /// @param account The account whose weight to retrieve.
    /// @return The weight assigned to the account.
    function getAccountWeight(address offer, address account) public view returns (uint256) {
        return offers[offer].weightOf[account];
    }
}
