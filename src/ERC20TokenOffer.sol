// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {IAccountWeightProvider} from "src/interfaces/IAccountWeightProvider.sol";
import {IERC20TokenOfferFactory} from "src/interfaces/IERC20TokenOfferFactory.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title ERC20TokenOffer
/// @notice Offers an ERC-20 token in exchange for CRC (Circles) during a fixed time window,
///         gating per-account purchase limits by a pluggable `IAccountWeightProvider`.
/// @dev
/// - The offer accepts CRC (ERC-1155) via Hub callbacks and sends out the ERC-20 token 1:price.
/// - `BASE_OFFER_LIMIT_IN_CRC` is scaled by the per-account weight: limit(account) = base * weight / WEIGHT_SCALE.
/// - Admin must pre-deposit the exact required token amount with `depositOfferTokens()` (finalizes weights).
/// - Availability requires: time window active AND tokens deposited.
/// - If `CREATED_BY_CYCLE == true`, only the Cycle can initiate claims (enforced in callbacks).
contract ERC20TokenOffer {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a non-owner calls an owner-only function.
    error OnlyOwner();

    /// @notice Thrown when a function that must be called by the Hub is called by another address.
    error OnlyHub();

    /// @notice Thrown when an incoming ERC-1155 id is not a trusted CRC token for this offer.
    /// @param id The unexpected/invalid token id.
    error InvalidTokenId(uint256 id);

    /// @notice Thrown when an account with zero computed limit attempts to claim.
    /// @param account The ineligible account.
    error IneligibleAccount(address account);

    /// @notice Thrown when a claim exceeds the remaining account limit.
    /// @param availableLimit Remaining CRC that the account can still spend.
    /// @param value Requested CRC spend amount.
    error ExceedsOfferLimit(uint256 availableLimit, uint256 value);

    /// @notice Thrown when an action requires the offer to be live but it is not in the active window.
    error OfferNotActive();

    /// @notice Thrown when trying to withdraw leftover tokens while the offer is still active.
    error OfferActive();

    /// @notice Thrown when an action requires deposited tokens but deposit has not happened yet.
    error OfferTokensNotDeposited();

    /// @notice Thrown when re-deposit is attempted after deposit is already completed (or after start if enforced).
    error OfferDepositClosed();

    /// @notice Thrown when the offer was created by Cycle and the caller is not the Cycle.
    error OnlyFromCycle();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after a successful claim.
    /// @param account The beneficiary that received the ERC-20 tokens.
    /// @param spent The CRC amount spent in this claim (units of CRC).
    /// @param received The ERC-20 token amount sent to `account` (in token decimals).
    event OfferClaimed(address indexed account, uint256 indexed spent, uint256 indexed received);

    /// @notice Emitted when the owner deposits offer tokens.
    /// @param amount The exact ERC-20 amount transferred in (in token decimals).
    event OfferTokensDeposited(uint256 indexed amount);

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether this offer instance was created by a Cycle (affects claim flow restrictions).
    bool public immutable CREATED_BY_CYCLE;

    /// @notice The offer owner (admin).
    address public immutable OWNER;

    /// @notice The ERC-20 token being offered.
    address public immutable TOKEN;

    /// @notice Cached `TOKEN.decimals()` for pricing arithmetic.
    uint256 internal immutable TOKEN_DECIMALS;

    /// @notice Pluggable provider for per-account weights, totals and finalization.
    IAccountWeightProvider public immutable ACCOUNT_WEIGHT_PROVIDER;

    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice Price: how many CRC units are required to buy 1 unit of ERC-20 token (before applying decimals).
    /// @dev Tokens dispensed on claim = `value * 10**TOKEN_DECIMALS / TOKEN_PRICE_IN_CRC`.
    uint256 public immutable TOKEN_PRICE_IN_CRC;

    /// @notice Base per-account CRC limit before weighting.
    /// @dev Effective account limit = `BASE_OFFER_LIMIT_IN_CRC * weight(account) / WEIGHT_SCALE`.
    uint256 public immutable BASE_OFFER_LIMIT_IN_CRC;

    /// @notice Offer start timestamp (inclusive).
    uint256 public immutable OFFER_START;

    /// @notice Offer end timestamp (inclusive).
    uint256 public immutable OFFER_END;

    /// @notice Scale factor used by the weight provider (e.g., 10_000 for basis points).
    uint256 public immutable WEIGHT_SCALE;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    /// @notice True once `depositOfferTokens()` has successfully transferred tokens in and finalized weights.
    bool public isOfferTokensDeposited;

    /// @notice Tracks CRC spent per account toward its weighted limit.
    /// @dev Units are CRC (same as `value` in claims).
    mapping(address account => uint256 spentAmount) public offerUsage;

    /// @notice Number of unique claimants (first-time claim counter).
    uint256 public claimantCount;

    /*//////////////////////////////////////////////////////////////
                            Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts execution to the designated `OWNER`.
    /// @dev Reverts with {OnlyOwner} when called by any other address.
    modifier onlyOwner() {
        if (msg.sender != OWNER) revert OnlyOwner();
        _;
    }

    /// @notice Restricts execution to calls coming from the Circles Hub.
    /// @dev Used by ERC-1155 receiver callbacks.
    modifier onlyHub() {
        if (msg.sender != address(HUB)) revert OnlyHub();
        _;
    }

    /// @notice Ensures the offer is currently active by time.
    /// @dev Active if `OFFER_START <= block.timestamp <= OFFER_END`. Reverts with {OfferNotActive} otherwise.
    modifier onlyWhileOfferActive() {
        if (block.timestamp < OFFER_START || block.timestamp > OFFER_END) {
            revert OfferNotActive();
        }
        _;
    }

    /// @notice Ensures that offer tokens have been deposited.
    /// @dev Used to block claims before inventory is secured.
    modifier onlyWhenOfferTokensDeposited() {
        if (!isOfferTokensDeposited) {
            revert OfferTokensNotDeposited();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           Constructor
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys an ERC20TokenOffer with fixed parameters and registers an org/trust in the Hub.
    /// @dev
    /// - Reads `isCreatedByCycle()` from the factory (msg.sender).
    /// - Caches token decimals and weight scale for cheaper reads later.
    /// - Registers this offer as an org in the Hub and trusts the provided `acceptedCRC` ids with max limit.
    /// - `offerDuration` MUST be > 0; `OFFER_END = offerStart + offerDuration`.
    /// @param accountWeightProvider Address of the `IAccountWeightProvider` used to compute per-account limits.
    /// @param offerOwner Offer owner (admin) address.
    /// @param offerToken ERC-20 token being offered.
    /// @param tokenPriceInCRC CRC required to buy 1 token unit (pre-decimals).
    /// @param offerLimitInCRC Base per-account CRC limit before weighting.
    /// @param offerStart Start timestamp (inclusive).
    /// @param offerDuration Duration in seconds (must be non-zero).
    /// @param orgName Organization name to register in the Hub.
    /// @param acceptedCRC Array of CRC token addresses/ids the offer accepts (trusted in Hub with max limit).
    constructor(
        address accountWeightProvider,
        address offerOwner,
        address offerToken,
        uint256 tokenPriceInCRC,
        uint256 offerLimitInCRC,
        uint256 offerStart,
        uint256 offerDuration,
        string memory orgName,
        address[] memory acceptedCRC
    ) {
        CREATED_BY_CYCLE = IERC20TokenOfferFactory(msg.sender).isCreatedByCycle();
        ACCOUNT_WEIGHT_PROVIDER = IAccountWeightProvider(accountWeightProvider);
        WEIGHT_SCALE = ACCOUNT_WEIGHT_PROVIDER.getWeightScale();
        OWNER = offerOwner;
        TOKEN = offerToken;
        TOKEN_DECIMALS = IERC20(TOKEN).decimals();
        TOKEN_PRICE_IN_CRC = tokenPriceInCRC;
        BASE_OFFER_LIMIT_IN_CRC = offerLimitInCRC;
        OFFER_START = offerStart;
        OFFER_END = offerStart + offerDuration;

        // Register an org and trust accepted CRC ids
        HUB.registerOrganization(orgName, 0);
        for (uint256 i; i < acceptedCRC.length;) {
            HUB.trust(acceptedCRC[i], type(uint96).max);
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                           View Helpers
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns true when the offer is in its active time window and tokens were deposited.
    function isOfferAvailable() external view returns (bool) {
        return OFFER_START <= block.timestamp && OFFER_END >= block.timestamp && isOfferTokensDeposited;
    }

    /// @notice Whether `account` has a positive weight (hence a non-zero limit).
    /// @return True if `ACCOUNT_WEIGHT_PROVIDER.getAccountWeight(account) > 0`.
    function isAccountEligible(address account) external view returns (bool) {
        return ACCOUNT_WEIGHT_PROVIDER.getAccountWeight(account) > 0;
    }

    /// @notice Total number of accounts with non-zero weight according to the provider.
    function getTotalEligibleAccounts() external view returns (uint256) {
        return ACCOUNT_WEIGHT_PROVIDER.getTotalAccounts();
    }

    /// @notice Returns the *weighted* CRC limit for `account`.
    /// @dev `limit = BASE_OFFER_LIMIT_IN_CRC * weight(account) / WEIGHT_SCALE`.
    function getAccountOfferLimit(address account) public view returns (uint256) {
        return BASE_OFFER_LIMIT_IN_CRC * ACCOUNT_WEIGHT_PROVIDER.getAccountWeight(account) / WEIGHT_SCALE;
    }

    /// @notice Returns how much CRC the `account` can still spend, net of previous usage.
    function getAvailableAccountOfferLimit(address account) external view returns (uint256) {
        return getAccountOfferLimit(account) - offerUsage[account];
    }

    /// @notice Computes the total ERC-20 token amount that must be deposited to cover all possible claims.
    /// @dev
    /// - Each account’s limit is:
    ///   `limit(account) = BASE_OFFER_LIMIT_IN_CRC * weight(account) / WEIGHT_SCALE`.
    /// - Summing across all accounts yields the total CRC capacity:
    ///   `totalCRC = BASE_OFFER_LIMIT_IN_CRC * totalWeight / WEIGHT_SCALE`.
    /// - To convert CRC capacity into ERC-20 tokens at the configured price:
    ///   `amount = totalCRC * 10**TOKEN_DECIMALS / TOKEN_PRICE_IN_CRC`.
    /// - This ensures consistency with `_claimOffer`, where payout = `value * 10**TOKEN_DECIMALS / TOKEN_PRICE_IN_CRC`.
    /// @return amount The exact ERC-20 token amount (already scaled by token decimals) that must be deposited.
    function getRequiredOfferTokenAmount() public view returns (uint256) {
        return (BASE_OFFER_LIMIT_IN_CRC * ACCOUNT_WEIGHT_PROVIDER.getTotalWeight() * (10 ** TOKEN_DECIMALS))
            / (WEIGHT_SCALE * TOKEN_PRICE_IN_CRC);
    }

    /*//////////////////////////////////////////////////////////////
                           Owner Actions
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits the exact ERC-20 token amount required and finalizes weights.
    /// @dev
    /// - Requires prior ERC-20 approval from `OWNER` to this contract for at least the required amount.
    /// - Calls `ACCOUNT_WEIGHT_PROVIDER.finalizeWeights()` to freeze eligibility/weights.
    /// - Reverts with {OfferDepositClosed} if already deposited (re-deposit not allowed).
    function depositOfferTokens() external onlyOwner {
        if (isOfferTokensDeposited || block.timestamp > OFFER_START) revert OfferDepositClosed();

        uint256 amount = getRequiredOfferTokenAmount();

        // Freeze weight provider
        ACCOUNT_WEIGHT_PROVIDER.finalizeWeights();

        // Pull ERC-20 from owner
        TOKEN.safeTransferFrom(OWNER, address(this), amount);

        isOfferTokensDeposited = true;

        emit OfferTokensDeposited(amount);
    }

    /// @notice Withdraws any unclaimed ERC-20 balance after the offer ends.
    /// @dev Reverts with {OfferActive} if called before or during the offer window.
    /// @return balance The amount transferred to `OWNER` (may be zero).
    function withdrawUnclaimedOfferTokens() external onlyOwner returns (uint256 balance) {
        if (OFFER_END > block.timestamp) revert OfferActive();
        balance = TOKEN.balanceOf(address(this));
        if (balance > 0) TOKEN.safeTransfer(OWNER, balance);
    }

    /*//////////////////////////////////////////////////////////////
                           Internal Logic
    //////////////////////////////////////////////////////////////*/

    /// @notice Core claim logic: enforces per-account limits and pays out ERC-20.
    /// @dev
    /// - `value` is the CRC spend amount (sum of ids for batch).
    /// - On first claim (when `availableLimit == accountLimit`), increments `claimantCount`.
    /// - Token payout: `amount = value * 10**TOKEN_DECIMALS / TOKEN_PRICE_IN_CRC`.
    /// @param account The beneficiary of the ERC-20 tokens.
    /// @param value The CRC amount being spent.
    /// @return amount The ERC-20 amount transferred to `account`.
    function _claimOffer(address account, uint256 value) internal returns (uint256 amount) {
        uint256 accountLimit = getAccountOfferLimit(account);

        if (accountLimit == 0) revert IneligibleAccount(account);

        uint256 availableLimit = accountLimit - offerUsage[account];
        if (availableLimit == accountLimit) ++claimantCount;
        if (availableLimit < value) revert ExceedsOfferLimit(availableLimit, value);

        offerUsage[account] += value;

        // Convert CRC spend to ERC-20 amount at the configured price
        amount = value * (10 ** TOKEN_DECIMALS) / TOKEN_PRICE_IN_CRC;
        TOKEN.safeTransfer(account, amount);

        emit OfferClaimed(account, value, amount);
    }

    /// @notice Resolve the ultimate CRC beneficiary when the offer is created by Cycle.
    /// @dev
    /// - Must only be called when `CREATED_BY_CYCLE` is true (enforced by the caller).
    /// - Requires `from == OWNER` (Cycle), otherwise reverts.
    /// - Decodes the beneficiary address from `data` (expects `abi.encode(address)`).
    /// - Reverts if `data` is malformed or not an encoded address.
    /// @param from The original CRC sender (must be `OWNER` when called under Cycle flow).
    /// @param data ABI-encoded beneficiary address (`abi.encode(address)`).
    /// @return sender The decoded beneficiary address.
    /// @custom:reverts OnlyFromCycle If `from != OWNER`.
    function _resolveSender(address from, bytes memory data) internal view returns (address sender) {
        if (from != OWNER) revert OnlyFromCycle();
        sender = abi.decode(data, (address));
    }

    /*//////////////////////////////////////////////////////////////
                         ERC-1155 Receiver (Hub)
    //////////////////////////////////////////////////////////////*/

    /// @notice Single-token CRC receipt handler (called by Hub), executes a claim and forwards CRC to `OWNER`.
    /// @dev
    /// - Validates `id` as a trusted CRC for this offer via
    ///   `HUB.isTrusted(address(this), address(uint160(id)))`.
    /// - If `CREATED_BY_CYCLE`:
    ///   - `from` must be `OWNER` (Cycle) or the call reverts inside `_resolveSender`.
    ///   - Beneficiary address is taken from `data` via `_resolveSender`.
    ///   - Forwards `(from, amount)` as encoded data on the Hub transfer to `OWNER`.
    /// - Returns the ERC-1155 receiver selector.
    /// @param from The original CRC sender reported by Hub (Cycle when `CREATED_BY_CYCLE`).
    /// @param id The CRC id being transferred in.
    /// @param value The CRC amount.
    /// @param data Optional encoded data. When `CREATED_BY_CYCLE == true`, must be `abi.encode(address beneficiary)`.
    /// @return The ERC-1155 `onERC1155Received` selector.
    /// @custom:reverts InvalidTokenId If `id` is not trusted for this offer.
    /// @custom:reverts OnlyFromCycle If `CREATED_BY_CYCLE` and `from != OWNER`.
    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes memory data)
        external
        onlyHub
        onlyWhenOfferTokensDeposited
        onlyWhileOfferActive
        returns (bytes4)
    {
        if (!HUB.isTrusted(address(this), address(uint160(id)))) revert InvalidTokenId(id);
        if (CREATED_BY_CYCLE) from = _resolveSender(from, data);

        uint256 amount = _claimOffer(from, value);
        data = CREATED_BY_CYCLE ? abi.encode(from, amount) : new bytes(0);

        // Forward CRC to the owner
        HUB.safeTransferFrom(address(this), OWNER, id, value, data);

        return this.onERC1155Received.selector;
    }

    /// @notice Batch CRC receipt handler (called by Hub), executes a claim on the sum and forwards CRCs to `OWNER`.
    /// @dev
    /// - Verifies each `ids[i]` is a trusted CRC for this offer and sums `values`.
    /// - If `CREATED_BY_CYCLE`:
    ///   - `from` must be `OWNER` (Cycle) or the call reverts inside `_resolveSender`.
    ///   - Beneficiary address is taken from `data` via `_resolveSender`.
    ///   - Forwards `(from, amount, totalValue)` as encoded data on the Hub batch transfer to `OWNER`.
    /// - Returns the ERC-1155 batch receiver selector.
    /// @param from The original CRC sender reported by Hub (Cycle when `CREATED_BY_CYCLE`).
    /// @param ids The CRC ids being transferred in.
    /// @param values The CRC amounts per id.
    /// @param data Optional encoded data. When `CREATED_BY_CYCLE == true`, must be `abi.encode(address beneficiary)`.
    /// @return The ERC-1155 `onERC1155BatchReceived` selector.
    /// @custom:reverts InvalidTokenId If any `ids[i]` is not trusted for this offer.
    /// @custom:reverts OnlyFromCycle If `CREATED_BY_CYCLE` and `from != OWNER`.
    function onERC1155BatchReceived(
        address,
        address from,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) external onlyHub onlyWhenOfferTokensDeposited onlyWhileOfferActive returns (bytes4) {
        uint256 totalValue;
        for (uint256 i; i < ids.length;) {
            if (!HUB.isTrusted(address(this), address(uint160(ids[i])))) revert InvalidTokenId(ids[i]);
            totalValue += values[i];
            unchecked {
                ++i;
            }
        }
        if (CREATED_BY_CYCLE) from = _resolveSender(from, data);

        uint256 amount = _claimOffer(from, totalValue);
        data = CREATED_BY_CYCLE ? abi.encode(from, amount, totalValue) : new bytes(0);

        // Forward CRC batch to the owner
        HUB.safeBatchTransferFrom(address(this), OWNER, ids, values, data);

        return this.onERC1155BatchReceived.selector;
    }
}
