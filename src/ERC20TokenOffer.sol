// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {IAccountScoreProvider} from "src/interfaces/IAccountScoreProvider.sol";

// TODO: add statistics: how many accounts in offer, how many accounts used offer

contract ERC20TokenOffer {
    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    error OfferDurationIsZero();

    error DenominatorIsZero();

    error OnlyOwner();

    error OnlyHub();

    error InvalidTokenId(uint256 id);

    error IneligibleAccount(address account);

    error ExceedsOfferLimit(uint256 availableLimit, uint256 value);

    error OfferNotActive();

    error OfferActive();

    error OfferTokensNotDeposited();

    error OfferDepositClosed();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    event OfferClaimed(address indexed account, uint256 indexed spent, uint256 indexed received);

    event OfferTokensDeposited(uint256 indexed amount);

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/
    address public immutable OWNER;
    address public immutable TOKEN; // = address(0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb);
    uint256 internal immutable TOKEN_DECIMALS;
    IAccountScoreProvider public immutable ACCOUNT_SCORE_PROVIDER; // ISSUE: problem is that i can't freeze updating the storage of this contract, so implementation should be known
    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    uint256 public immutable TOKEN_PRICE_IN_CRC;
    uint256 public immutable BASE_OFFER_LIMIT_IN_CRC; // = 500 ether;
    uint256 public immutable OFFER_START;
    uint256 public immutable OFFER_END;

    uint256 public immutable SCORE_DENOMINATOR;

    // for daily extension
    // uint256 public dailyLimit = 100 ether;

    // for tiers extension
    // uint256 internal constant ONE_IN_BASIS_POINTS = 10_000;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    bool isOfferTokensDeposited;

    mapping(uint256 id => bool) public acceptedIds;

    mapping(address account => uint256 spentAmount) public offerUsage;

    /*//////////////////////////////////////////////////////////////
                            Modifiers
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Restricts function execution to the designated OWNER address.
     *      Reverts with `OnlyOwner` if called by any other address.
     */
    modifier onlyOwner() {
        if (msg.sender != OWNER) revert OnlyOwner();
        _;
    }

    modifier onlyHub() {
        if (msg.sender != address(HUB)) revert OnlyHub();
        _;
    }

    modifier onlyWhileOfferActive() {
        if (block.timestamp < OFFER_START || block.timestamp > OFFER_END) {
            revert OfferNotActive();
        }
        _;
    }

    modifier onlyWhenOfferTokensDeposited() {
        if (!isOfferTokensDeposited) {
            revert OfferTokensNotDeposited();
        }
        _;
    }

    constructor(
        address offerOwner,
        address offerToken,
        address accountScoreProvider,
        uint256 tokenPriceInCRC,
        uint256 offerLimitInCRC,
        uint256 offerStart,
        uint256 offerDuration,
        string memory orgName,
        address[] memory acceptedCRC
    ) {
        OWNER = offerOwner;
        TOKEN = offerToken;
        TOKEN_DECIMALS = IERC20(TOKEN).decimals();
        ACCOUNT_SCORE_PROVIDER = IAccountScoreProvider(accountScoreProvider);
        SCORE_DENOMINATOR = ACCOUNT_SCORE_PROVIDER.getScoreDenominator();
        if (SCORE_DENOMINATOR == 0) revert DenominatorIsZero();
        TOKEN_PRICE_IN_CRC = tokenPriceInCRC;
        BASE_OFFER_LIMIT_IN_CRC = offerLimitInCRC;
        if (offerDuration == 0) revert OfferDurationIsZero();
        OFFER_START = offerStart;
        OFFER_END = offerStart + offerDuration;

        // register an org
        HUB.registerOrganization(orgName, 0);
        for (uint256 i; i < acceptedCRC.length;) {
            HUB.trust(acceptedCRC[i], type(uint96).max);
            acceptedIds[uint256(uint160(acceptedCRC[i]))] = true;
            unchecked {
                ++i;
            }
        }
    }

    function isOfferAvailable() external view returns (bool) {
        return OFFER_START <= block.timestamp && OFFER_END >= block.timestamp && isOfferTokensDeposited;
    }

    function isAccountEligible(address account) external view returns (bool) {
        return ACCOUNT_SCORE_PROVIDER.getAccountScore(account) > 0;
    }

    function getAccountOfferLimit(address account) public view returns (uint256) {
        return BASE_OFFER_LIMIT_IN_CRC * ACCOUNT_SCORE_PROVIDER.getAccountScore(account) / SCORE_DENOMINATOR;
    }

    function getAvailableAccountOfferLimit(address account) external view returns (uint256) {
        return getAccountOfferLimit(account) - offerUsage[account];
    }

    function getRequiredOfferTokenAmount() public view returns (uint256) {
        return BASE_OFFER_LIMIT_IN_CRC * ACCOUNT_SCORE_PROVIDER.getTotalAccountScore() / SCORE_DENOMINATOR;
    }

    /// requires token pre-approval
    function depositOfferTokens() external onlyOwner {
        // Q: should it be allowed to deposit after offer start?
        //if (block.timestamp > OFFER_START) revert OfferDepositClosed();
        if (isOfferTokensDeposited) revert OfferDepositClosed();

        // token amount

        uint256 amount = getRequiredOfferTokenAmount();

        // freeze score_provider
        ACCOUNT_SCORE_PROVIDER.finalizeScores();

        // receieve token
        IERC20(TOKEN).transferFrom(OWNER, address(this), amount);

        isOfferTokensDeposited = true;

        emit OfferTokensDeposited(amount);
    }

    function withdrawUnclaimedOfferTokens() external onlyOwner {
        if (OFFER_END > block.timestamp) revert OfferActive();
        uint256 balance = IERC20(TOKEN).balanceOf(address(this));
        IERC20(TOKEN).transfer(OWNER, balance);
    }

    // admin trust function

    function _claimOffer(address account, uint256 value) internal {
        uint256 accountLimit = getAccountOfferLimit(account);

        if (accountLimit == 0) revert IneligibleAccount(account);

        uint256 availableLimit = accountLimit - offerUsage[account];
        if (availableLimit < value) revert ExceedsOfferLimit(availableLimit, value);

        offerUsage[account] += value;

        // transfer token
        uint256 amount = value * (10 ** TOKEN_DECIMALS) / TOKEN_PRICE_IN_CRC;
        IERC20(TOKEN).transfer(account, amount);

        emit OfferClaimed(account, value, amount);
    }

    // callback

    function onERC1155Received(address, /*operator*/ address from, uint256 id, uint256 value, bytes calldata /*data*/ )
        external
        onlyHub
        onlyWhenOfferTokensDeposited
        onlyWhileOfferActive
        returns (bytes4)
    {
        if (!acceptedIds[id]) revert InvalidTokenId(id);

        _claimOffer(from, value);

        // transfer to owner
        HUB.safeTransferFrom(address(this), OWNER, id, value, "");

        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address, /*operator*/
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata /*data*/
    ) external onlyHub onlyWhenOfferTokensDeposited onlyWhileOfferActive returns (bytes4) {
        uint256 totalValue;
        for (uint256 i; i < ids.length; i++) {
            if (!acceptedIds[ids[i]]) revert InvalidTokenId(ids[i]);
            totalValue += values[i];
            unchecked {
                ++i;
            }
        }

        _claimOffer(from, totalValue);

        // transfer to owner
        HUB.safeBatchTransferFrom(address(this), OWNER, ids, values, "");

        return this.onERC1155BatchReceived.selector;
    }
}
