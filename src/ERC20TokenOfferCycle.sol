// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20TokenOfferFactory} from "src/interfaces/IERC20TokenOfferFactory.sol";
import {IAccountWeightProvider} from "src/interfaces/IAccountWeightProvider.sol";
import {IERC20TokenOffer} from "src/interfaces/IERC20TokenOffer.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title ERC20TokenOfferCycle
/// @notice Orchestrates recurring ERC20 token offers (time-based cycles) that sell an ERC-20 for CRC via the Circles Hub.
/// @dev
/// - Uses a shared `IAccountWeightProvider` instance for all offers in the cycle.
/// - Each “offer period” is `OFFER_DURATION` seconds; `currentOfferId()` derives the active one from time.
/// - `createNextOffer(...)` deploys the next offer (id = current + 1) via the factory and wires CRC trust.
/// - `depositNextOfferTokens()` pre-funds the next offer and triggers its weight finalization (via the offer).
/// - Hub callbacks proxy inbound CRC to the active offer and proxy outbound CRC from the offer to the admin,
///   while tracking `totalClaimed` per beneficiary and enforcing optional soft-locks.
contract ERC20TokenOfferCycle {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller is not the cycle admin.
    error OnlyAdmin();

    /// @notice Thrown when a function that must be called by the Hub is called by another address.
    error OnlyHub();

    /// @notice Thrown if the next offer already exists *and* has been funded.
    error NextOfferTokensAreAlreadyDeposited();

    /// @notice Thrown when soft-lock is enabled and a user tries to spend CRC exceeding their ERC20 balance (net of claimed).
    error SoftLock();

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted once at construction with the cycle’s immutable configuration.
    /// @param admin Cycle admin.
    /// @param accountWeightProvider Address of the shared weight provider used by offers.
    /// @param offerToken ERC-20 token sold by offers.
    /// @param offersStart First offer’s start timestamp (inclusive).
    /// @param offerDuration Duration (in seconds) of each offer period.
    /// @param softLockEnabled Whether soft-lock checks are enforced on CRC forwarding.
    event CycleConfiguration(
        address indexed admin,
        address indexed accountWeightProvider,
        address indexed offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        bool softLockEnabled
    );

    /// @notice Emitted when the next offer is created via the factory.
    /// @param nextOffer Address of the newly created offer.
    /// @param tokenPriceInCRC Price in CRC used by the offer.
    /// @param offerLimitInCRC Base per-account CRC limit at that offer.
    /// @param acceptedCRC List of CRC ids trusted for the offer.
    event NextOfferCreated(
        address indexed nextOffer,
        uint256 indexed tokenPriceInCRC,
        uint256 indexed offerLimitInCRC,
        address[] acceptedCRC
    );

    /// @notice Emitted when the next offer is pre-funded with ERC-20.
    /// @param nextOffer Address of the offer funded.
    /// @param amount ERC-20 amount deposited (already scaled by token decimals).
    event NextOfferTokensDeposited(address indexed nextOffer, uint256 indexed amount);

    /// @notice Emitted after syncing Hub trust end-times for the active offer period.
    /// @param offerId The current (active) offer id whose trust was synced.
    /// @param offer Address of the current offer.
    event OfferTrustSynced(uint256 indexed offerId, address indexed offer);

    /// @notice Emitted when a claim completes (observed via Hub callback from the offer).
    /// @param offer Offer that paid out the ERC-20.
    /// @param account Beneficiary who received the ERC-20.
    /// @param received ERC-20 amount paid (token decimals).
    /// @param spent CRC spent for this claim.
    event OfferClaimed(address indexed offer, address indexed account, uint256 indexed received, uint256 spent);

    /// @notice Emitted when unclaimed ERC-20 is withdrawn from a past offer.
    /// @param offer Offer that returned leftover inventory.
    /// @param amount ERC-20 amount withdrawn to admin.
    event UnclaimedTokensWithdrawn(address indexed offer, uint256 indexed amount);

    /*//////////////////////////////////////////////////////////////
                              Constants & Immutables
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice Factory used to create offers and the shared weight provider.
    IERC20TokenOfferFactory public immutable OFFER_FACTORY;

    /// @notice Cycle admin.
    address public immutable ADMIN;

    /// @notice Shared account weight provider used by all offers in the cycle.
    IAccountWeightProvider public immutable ACCOUNT_WEIGHT_PROVIDER;

    /// @notice ERC-20 token sold by each offer in this cycle.
    address public immutable OFFER_TOKEN;

    /// @notice Timestamp when the first offer starts (inclusive).
    uint256 public immutable OFFERS_START;

    /// @notice Duration of each offer period in seconds.
    uint256 public immutable OFFER_DURATION;

    /// @notice If true, enforce that a user cannot forward CRC to current offer if claimed ERC-20 exceeds their wallet balance.
    bool public immutable SOFT_LOCK_ENABLED;

    /*//////////////////////////////////////////////////////////////
                                  Storage
    //////////////////////////////////////////////////////////////*/

    /// @notice Base prefix used to construct per-offer org names (human-readable).
    string public offerOrgName;

    /// @notice Mapping: offerId => offer instance.
    mapping(uint256 => IERC20TokenOffer) public offers;

    /// @notice Mapping: offerId => list of accepted CRC ids (trusted in Hub).
    mapping(uint256 => address[]) public acceptedCRC;

    /// @notice Aggregated ERC-20 received by each account across all offers in the cycle.
    mapping(address => uint256) public totalClaimed;

    /*//////////////////////////////////////////////////////////////
                                 Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts to cycle admin.
    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert OnlyAdmin();
        _;
    }

    /// @notice Restricts to Hub callbacks.
    modifier onlyHub() {
        if (msg.sender != address(HUB)) revert OnlyHub();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               Constructor
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes a cycle, creates the shared weight provider via the factory, and registers a Hub org.
    /// @dev
    /// - The shared provider is created with `createAccountWeightProvider(address(this))`.
    /// - Registers an organization in Hub under `orgName` (human label).
    /// - Emits {CycleConfiguration}.
    /// @param admin Cycle admin address.
    /// @param offerToken ERC-20 token to be sold by offers in this cycle.
    /// @param offersStart First offer start timestamp (inclusive).
    /// @param offerDuration Duration for each offer period (seconds).
    /// @param enableSoftLock Enable/disable soft-lock checks on CRC forwarding.
    /// @param offerName Prefix used to construct per-offer display names.
    /// @param orgName Human-readable org name to register in the Hub.
    constructor(
        address admin,
        address offerToken,
        uint256 offersStart,
        uint256 offerDuration,
        bool enableSoftLock,
        string memory offerName,
        string memory orgName
    ) {
        OFFER_FACTORY = IERC20TokenOfferFactory(msg.sender);
        ACCOUNT_WEIGHT_PROVIDER = IAccountWeightProvider(OFFER_FACTORY.createAccountWeightProvider(address(this)));
        ADMIN = admin;
        OFFER_TOKEN = offerToken;
        OFFERS_START = offersStart;
        OFFER_DURATION = offerDuration;
        SOFT_LOCK_ENABLED = enableSoftLock;
        offerOrgName = offerName;

        // Register an org for the cycle.
        HUB.registerOrganization(orgName, 0);

        emit CycleConfiguration(
            ADMIN, address(ACCOUNT_WEIGHT_PROVIDER), OFFER_TOKEN, OFFERS_START, OFFER_DURATION, SOFT_LOCK_ENABLED
        );
    }

    /*//////////////////////////////////////////////////////////////
                                View Helpers
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes the current offer id based on time.
    /// @dev
    /// - Returns 0 if now < `OFFERS_START`.
    /// - Otherwise: `((block.timestamp - OFFERS_START) / OFFER_DURATION) + 1`.
    function currentOfferId() public view returns (uint256) {
        if (block.timestamp < OFFERS_START) return 0;
        return ((block.timestamp - OFFERS_START) / OFFER_DURATION) + 1;
    }

    /// @notice Returns the currently active offer instance (may be zero address if not created).
    function currentOffer() public view returns (IERC20TokenOffer offer) {
        offer = offers[currentOfferId()];
    }

    /*//////////////////////////////////////////////////////////////
                            Offer Creation & Setup
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates the next offer (id = current + 1) via the factory and records its accepted CRC ids.
    /// @dev
    /// - Reverts if a next offer exists and is already funded (prevents overwriting a funded offer).
    /// - The new offer’s start time is contiguous to the current schedule: `OFFERS_START + OFFER_DURATION * currentId`.
    /// - Org/offer name is built as `offerOrgName-{id}`.
    /// @param tokenPriceInCRC Price in CRC for the next offer.
    /// @param offerLimitInCRC Base per-account CRC limit for the next offer (pre-weight).
    /// @param _acceptedCRC List of CRC ids the next offer will accept and trust in Hub.
    /// @return nextOffer Address of the newly created offer.
    function createNextOffer(uint256 tokenPriceInCRC, uint256 offerLimitInCRC, address[] memory _acceptedCRC)
        external
        onlyAdmin
        returns (address nextOffer)
    {
        uint256 currentId = currentOfferId();
        nextOffer = address(offers[currentId + 1]);
        // If the next offer exists and has already been funded, abort.
        if (nextOffer != address(0) && IERC20TokenOffer(nextOffer).isOfferTokensDeposited()) {
            revert NextOfferTokensAreAlreadyDeposited();
        }
        uint256 offerStart = OFFERS_START + (OFFER_DURATION * currentId);

        string memory offerName = string.concat(offerOrgName, "-", LibString.toString(currentId + 1));

        nextOffer = OFFER_FACTORY.createERC20TokenOffer(
            address(ACCOUNT_WEIGHT_PROVIDER),
            address(this),
            OFFER_TOKEN,
            tokenPriceInCRC,
            offerLimitInCRC,
            offerStart, // contiguous start
            OFFER_DURATION,
            offerName,
            _acceptedCRC
        );

        offers[currentId + 1] = IERC20TokenOffer(nextOffer);
        acceptedCRC[currentId + 1] = _acceptedCRC;

        emit NextOfferCreated(nextOffer, tokenPriceInCRC, offerLimitInCRC, _acceptedCRC);
    }

    /// @notice Batches account weights for the *next* offer id (current + 1) using the shared provider.
    /// @dev This writes into the provider’s scope keyed by the next offer address.
    /// @param accounts Accounts to configure.
    /// @param weights Non-negative weights to set (unbounded/graded). Zero removes eligibility.
    function setNextOfferAccountWeights(address[] memory accounts, uint256[] memory weights) external onlyAdmin {
        address nextOffer = address(offers[currentOfferId() + 1]);
        ACCOUNT_WEIGHT_PROVIDER.setAccountWeights(nextOffer, accounts, weights);
    }

    /// @notice Pre-funds the next offer with the exact ERC-20 amount and triggers its finalize-on-deposit flow.
    /// @dev
    /// - Requires prior ERC-20 approval from admin to this cycle for at least the required amount.
    /// - Safe-approves the next offer, which then pulls the funds in `depositOfferTokens()`.
    /// - Emits {NextOfferTokensDeposited}.
    function depositNextOfferTokens() external onlyAdmin {
        (IERC20TokenOffer nextOffer, uint256 requiredAmount) = getNextOfferAndRequiredTokenAmount();
        OFFER_TOKEN.safeTransferFrom(ADMIN, address(this), requiredAmount);
        OFFER_TOKEN.safeApprove(address(nextOffer), requiredAmount);

        nextOffer.depositOfferTokens();

        emit NextOfferTokensDeposited(address(nextOffer), requiredAmount);
    }

    /// @notice Syncs Hub trust end-times for the *current* offer to its natural end.
    /// @dev Sets `trust(receiver, offerEnd)` for each accepted CRC id of the current offer.
    function syncOfferTrust() external {
        uint256 currentId = currentOfferId();
        uint96 offerEnd = uint96(OFFERS_START + (OFFER_DURATION * currentId));
        address[] memory trustReceivers = acceptedCRC[currentId];

        for (uint256 i; i < trustReceivers.length;) {
            HUB.trust(trustReceivers[i], offerEnd);
            unchecked {
                ++i;
            }
        }
        emit OfferTrustSynced(currentId, address(offers[currentId]));
    }

    /// @notice Withdraws leftover ERC-20 from a past offer and forwards it to the admin.
    /// @param offerId The offer to withdraw from.
    function withdrawUnclaimedOfferTokens(uint256 offerId) external onlyAdmin {
        IERC20TokenOffer offer = offers[offerId];
        uint256 amount = offer.withdrawUnclaimedOfferTokens();
        if (amount > 0) {
            OFFER_TOKEN.safeTransfer(ADMIN, amount);
            emit UnclaimedTokensWithdrawn(address(offer), amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           Offer Facade (Active)
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether the current offer is available (time window & funded).
    function isOfferAvailable() external view returns (bool) {
        return currentOffer().isOfferAvailable();
    }

    /// @notice Whether `account` is eligible under the current offer (weight > 0).
    function isAccountEligible(address account) external view returns (bool) {
        return currentOffer().isAccountEligible(account);
    }

    /// @notice Number of eligible accounts (non-zero weight) for the current offer.
    function getTotalEligibleAccounts() external view returns (uint256) {
        return currentOffer().getTotalEligibleAccounts();
    }

    /// @notice Number of unique claimants for the current offer.
    function getClaimantCount() external view returns (uint256) {
        return currentOffer().claimantCount();
    }

    /// @notice Weighted CRC limit for `account` in the current offer.
    function getAccountOfferLimit(address account) public view returns (uint256) {
        return currentOffer().getAccountOfferLimit(account);
    }

    /// @notice Remaining CRC `account` can still spend in the current offer.
    function getAvailableAccountOfferLimit(address account) external view returns (uint256) {
        return currentOffer().getAvailableAccountOfferLimit(account);
    }

    /// @notice Returns the next offer and the ERC-20 amount it requires to fully back all potential claims.
    /// @return nextOffer The next (current+1) offer instance (may be zero address if not created yet).
    /// @return requiredTokenAmount ERC-20 token amount (token decimals) required by the next offer.
    function getNextOfferAndRequiredTokenAmount()
        public
        view
        returns (IERC20TokenOffer nextOffer, uint256 requiredTokenAmount)
    {
        nextOffer = offers[currentOfferId() + 1];
        requiredTokenAmount = nextOffer.getRequiredOfferTokenAmount();
    }

    /*//////////////////////////////////////////////////////////////
                               Hub Callbacks
    //////////////////////////////////////////////////////////////*/

    /// @notice Hub single-token callback. Forwards inbound CRC either to admin (post-claim) or to the active offer.
    /// @dev
    /// - If `from == currentOffer()`: this is the *post-claim* leg; decode `(account, amount)` from `data`,
    ///   accumulate `totalClaimed[account]`, emit {OfferClaimed}, then forward CRC to `ADMIN`.
    /// - Else: this is a *pre-claim* leg from a user; enforce optional `SOFT_LOCK_ENABLED`
    ///   (`totalClaimed[from] <= OFFER_TOKEN.balanceOf(from)`), encode `from` into `data`, forward CRC to `currentOffer()`.
    /// - Returns the ERC-1155 receiver selector.
    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes memory data)
        external
        onlyHub
        returns (bytes4)
    {
        address offerAddress = address(currentOffer());
        if (from == offerAddress) {
            // Post-claim: track the payout and forward CRC to admin.
            (address account, uint256 amount) = abi.decode(data, (address, uint256));
            totalClaimed[account] += amount;
            emit OfferClaimed(offerAddress, account, amount, value);
            HUB.safeTransferFrom(address(this), ADMIN, id, value, "");
            return this.onERC1155Received.selector;
        }

        // Pre-claim: enforce optional soft-lock and forward CRC to current offer.
        if (SOFT_LOCK_ENABLED && totalClaimed[from] > OFFER_TOKEN.balanceOf(from)) revert SoftLock();
        data = abi.encode(from);

        HUB.safeTransferFrom(address(this), offerAddress, id, value, data);

        return this.onERC1155Received.selector;
    }

    /// @notice Hub batch callback. Mirrors the single-token flow for batches.
    /// @dev
    /// - Post-claim branch decodes `(account, amount, value)` from `data` and forwards CRC batch to admin.
    /// - Pre-claim branch enforces soft-lock (if enabled), encodes `from`, and forwards batch to current offer.
    /// - Returns the ERC-1155 batch receiver selector.
    function onERC1155BatchReceived(
        address,
        address from,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) external onlyHub returns (bytes4) {
        address offerAddress = address(currentOffer());
        if (from == offerAddress) {
            // Post-claim: track payout and forward CRC to admin.
            (address account, uint256 amount, uint256 value) = abi.decode(data, (address, uint256, uint256));
            totalClaimed[account] += amount;
            emit OfferClaimed(offerAddress, account, amount, value);
            HUB.safeBatchTransferFrom(address(this), ADMIN, ids, values, "");
            return this.onERC1155BatchReceived.selector;
        }

        // Pre-claim: enforce optional soft-lock and forward CRC to current offer.
        if (SOFT_LOCK_ENABLED && totalClaimed[from] > OFFER_TOKEN.balanceOf(from)) revert SoftLock();
        data = abi.encode(from);

        HUB.safeBatchTransferFrom(address(this), offerAddress, ids, values, data);

        return this.onERC1155BatchReceived.selector;
    }
}
