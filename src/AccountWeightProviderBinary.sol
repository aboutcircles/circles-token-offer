// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IAccountWeightProvider} from "src/interfaces/IAccountWeightProvider.sol";
import {IHub} from "src/interfaces/IHub.sol";

/// @title IEligibilityOrganization
/// @notice Minimal facade used by {AccountWeightProviderBinary} to batch-trust/untrust accounts in the Circles Hub.
/// @dev Implementations SHOULD interpret any nonzero `weights[i]` as "eligible" and zero as "ineligible".
interface IEligibilityOrganization {
    /// @notice Updates trust for `accounts` according to `weights`.
    /// @dev
    /// - For each index `i`:
    ///   - if `weights[i] > 0`, the organization SHOULD trust `accounts[i]` with a max limit
    ///   - if `weights[i] == 0`, the organization SHOULD set trust to zero (untrust)
    /// - Return counters let the caller update accounting without re-iterating.
    /// @param accounts The accounts to trust/untrust.
    /// @param weights Binary-intent weights; zero => untrust, nonzero => trust.
    /// @return totalTrusted Number of accounts newly trusted by this call.
    /// @return totalUntrusted Number of accounts newly untrusted by this call.
    function trust(address[] memory accounts, uint256[] memory weights)
        external
        returns (uint256 totalTrusted, uint256 totalUntrusted);
}

/// @title EligibilityOrganization
/// @notice Organization wrapper that toggles trust in the Circles v2 Hub based on binary weights.
/// @dev
/// - Deploys and auto-registers itself in the Hub on construction.
/// - `trust(...)` uses `HUB.trust(account, limit)` with `type(uint96).max` to trust and `0` to untrust.
/// - Only the deployer (immutable `ADMIN`) may call `trust`.
contract EligibilityOrganization {
    /// @notice Revert when caller is not the admin.
    error OnlyAdmin();

    /// @notice Admin address authorized to perform trust updates.
    address public immutable ADMIN;

    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice Registers this organization in the Circles Hub.
    /// @dev Uses empty name and zero metadata hash.
    constructor() {
        ADMIN = msg.sender;
        HUB.registerOrganization("", bytes32(0));
    }

    /// @notice Trusts/untrusts `accounts` according to `weights` (nonzero => trust, zero => untrust).
    /// @dev
    /// - Idempotent per account/intent: re-trusting an already trusted account or re-untrusting an already untrusted account has no effect.
    /// - Returns counters so callers can update accounting in O(1) post-loop.
    /// @param accounts Accounts to modify.
    /// @param weights Binary-intent weights; nonzero => trust at max limit, zero => untrust (set limit to 0).
    /// @return totalTrusted Number of accounts newly trusted by this call.
    /// @return totalUntrusted Number of accounts newly untrusted by this call.
    function trust(address[] memory accounts, uint256[] memory weights)
        external
        returns (uint256 totalTrusted, uint256 totalUntrusted)
    {
        if (msg.sender != ADMIN) revert OnlyAdmin();

        for (uint256 i; i < accounts.length;) {
            bool alreadyTrusted = HUB.isTrusted(address(this), accounts[i]);

            if (weights[i] > 0 && !alreadyTrusted) {
                HUB.trust(accounts[i], type(uint96).max);
                ++totalTrusted;
            } else if (weights[i] == 0 && alreadyTrusted) {
                HUB.trust(accounts[i], uint96(0));
                ++totalUntrusted;
            }

            unchecked {
                ++i;
            }
        }
    }
}

/// @title AccountWeightProviderBinary
/// @notice Binary implementation of `IAccountWeightProvider` that maps eligibility to Hub trust:
///         weight = 0 if not trusted; weight = `getWeightScale()` if trusted.
/// @dev
/// - Uses a per-offer `EligibilityOrganization` to set Hub trust from the admin’s batch updates.
/// - `getWeightScale()` returns 10_000 (basis points).
/// - `getTotalWeight()` = `totalAccounts * getWeightScale()` since all eligible accounts share the same weight.
/// - After `finalizeWeights()`, further writes via `setAccountWeights` MUST revert with `WeightsAlreadyFinalized`.
contract AccountWeightProviderBinary is IAccountWeightProvider {
    /// @notice Per-offer eligibility bookkeeping.
    /// @param totalAccounts Number of accounts currently trusted (eligible).
    /// @param eligibilityOrg The organization contract used to trust/untrust in the Hub.
    /// @param finalized Whether the offer’s weights have been finalized (further writes disabled).
    struct OfferEligibility {
        uint256 totalAccounts;
        address eligibilityOrg;
        bool finalized;
    }

    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function is called by a non-admin address.
    error OnlyAdmin();

    /// @notice Thrown when `accounts.length != weights.length`.
    error ArrayLengthMismatch();

    /// @notice Thrown when attempting to modify weights after they have been finalized for an offer.
    error WeightsAlreadyFinalized();

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice Weight scale (basis points).
    uint256 internal constant ONE_IN_BASIS_POINTS = 10_000;

    /// @notice The single admin allowed to set weights.
    address public immutable ADMIN;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping of offer => eligibility data.
    mapping(address offer => OfferEligibility) public offers;

    /*//////////////////////////////////////////////////////////////
                           Constructor
    //////////////////////////////////////////////////////////////*/

    /// @param admin The address authorized to call admin-only functions.
    constructor(address admin) {
        ADMIN = admin;
    }

    /*//////////////////////////////////////////////////////////////
                        Admin Function (Writes)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAccountWeightProvider
    /// @dev
    /// - Binary semantics: `weights[i] == 0` => ineligible (untrust); `weights[i] > 0` => eligible (trust).
    /// - Lazily deploys a fresh `EligibilityOrganization` for `offer` on first write.
    /// - Reverts if `offers[offer].finalized` is true.
    function setAccountWeights(address offer, address[] memory accounts, uint256[] memory weights) external {
        if (msg.sender != ADMIN) revert OnlyAdmin();
        if (accounts.length != weights.length) revert ArrayLengthMismatch();

        OfferEligibility storage offerEligibility = offers[offer];
        if (offerEligibility.finalized) revert WeightsAlreadyFinalized();

        // Lazy-create the per-offer org that holds Hub trust state.
        if (offerEligibility.eligibilityOrg == address(0)) {
            offerEligibility.eligibilityOrg = address(new EligibilityOrganization());
        }

        (uint256 totalTrusted, uint256 totalUntrusted) =
            IEligibilityOrganization(offerEligibility.eligibilityOrg).trust(accounts, weights);

        // Update accounting from returned deltas.
        if (totalUntrusted > 0) offerEligibility.totalAccounts -= totalUntrusted;
        if (totalTrusted > 0) offerEligibility.totalAccounts += totalTrusted;
    }

    /*//////////////////////////////////////////////////////////////
                             Lifecycle
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAccountWeightProvider
    /// @dev Emits {WeightsFinalized} with `totalWeight = totalAccounts * ONE_IN_BASIS_POINTS` if any accounts are eligible.
    function finalizeWeights() external {
        offers[msg.sender].finalized = true;
        uint256 accountsCount = offers[msg.sender].totalAccounts;
        if (accountsCount > 0) {
            emit WeightsFinalized(msg.sender, accountsCount, accountsCount * ONE_IN_BASIS_POINTS);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    View Functions (Specific to Offer)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAccountWeightProvider
    function getWeightScale() external pure returns (uint256) {
        return ONE_IN_BASIS_POINTS;
    }

    /// @inheritdoc IAccountWeightProvider
    function getAccountWeight(address account) external view returns (uint256) {
        if (HUB.isTrusted(offers[msg.sender].eligibilityOrg, account)) return ONE_IN_BASIS_POINTS;
        else return 0;
    }

    /// @inheritdoc IAccountWeightProvider
    function getTotalWeight() external view returns (uint256) {
        return offers[msg.sender].totalAccounts * ONE_IN_BASIS_POINTS;
    }

    /// @inheritdoc IAccountWeightProvider
    function getTotalAccounts() external view returns (uint256) {
        return offers[msg.sender].totalAccounts;
    }
}
