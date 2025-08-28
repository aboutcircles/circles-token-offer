// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

/// @notice Provides per-account eligibility weights.
/// Weights are integers measured in units of `getWeightScale()`.
/// - 0          => ineligible
/// - Binary impls: weight ∈ {0, getWeightScale()}
/// - Graded impls: weight ∈ [0, ∞); MAY exceed getWeightScale() (e.g., boosts > 100%).
interface IAccountWeightProvider {
    /// @notice Emitted once an offer finalizes its weights, locking further modifications.
    /// @param offer The offer whose weights have been finalized (always msg.sender at emit time).
    /// @param accountsCount Number of accounts with nonzero weight for this offer.
    /// @param totalWeight Sum of all per-account weights for this offer.
    event WeightsFinalized(address indexed offer, uint256 indexed accountsCount, uint256 indexed totalWeight);

    /// @notice Returns the scale used to interpret weights (e.g., 10_000 for basis points).
    /// @return The weight scale.
    function getWeightScale() external view returns (uint256);

    // Reads scoped to calling offer (msg.sender)

    /// @notice Returns the weight of `account` for the calling offer (`msg.sender`).
    /// @param account The account to query.
    /// @return weight The assigned weight for `account`.
    function getAccountWeight(address account) external view returns (uint256 weight);

    /// @notice Returns the total weight across all accounts for the calling offer (`msg.sender`).
    /// @return total The sum of all per-account weights.
    function getTotalWeight() external view returns (uint256 total);

    /// @notice Returns the number of accounts with a nonzero weight for the calling offer (`msg.sender`).
    /// @return The count of accounts with nonzero weight.
    function getTotalAccounts() external view returns (uint256);

    // Admin writes / lifecycle

    /// @notice Sets or updates weights for a batch of `accounts` for a specific `offer`.
    /// @dev Implementations SHOULD revert if arrays differ in length or if weights are finalized.
    /// @param offer The offer whose weights are being set.
    /// @param accounts The list of accounts to set weights for.
    /// @param weights The corresponding weights to assign to each account.
    function setAccountWeights(address offer, address[] memory accounts, uint256[] memory weights) external;

    /// @notice Finalizes weights for the calling offer (`msg.sender`), permanently preventing further changes.
    /// @dev SHOULD emit {WeightsFinalized} if at least one account has nonzero weight.
    function finalizeWeights() external;
}
