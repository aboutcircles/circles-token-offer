// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {IAccountWeightProvider} from "src/interfaces/IAccountWeightProvider.sol";
import {IERC20TokenOfferFactory} from "src/interfaces/IERC20TokenOfferFactory.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract ERC20TokenOffer {
    using SafeTransferLib for address;
    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    error OfferDurationIsZero();

    error OnlyOwner();

    error OnlyHub();

    error InvalidTokenId(uint256 id);

    error IneligibleAccount(address account);

    error ExceedsOfferLimit(uint256 availableLimit, uint256 value);

    error OfferNotActive();

    error OfferActive();

    error OfferTokensNotDeposited();

    error OfferDepositClosed();

    error OnlyFromCycle();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    event OfferClaimed(address indexed account, uint256 indexed spent, uint256 indexed received);

    event OfferTokensDeposited(uint256 indexed amount);

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/
    bool public immutable CREATED_BY_CYCLE;
    address public immutable OWNER;
    address public immutable TOKEN;
    uint256 internal immutable TOKEN_DECIMALS;
    IAccountWeightProvider public immutable ACCOUNT_WEIGHT_PROVIDER;
    /// @notice Circles v2 Hub.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    uint256 public immutable TOKEN_PRICE_IN_CRC;
    uint256 public immutable BASE_OFFER_LIMIT_IN_CRC;
    uint256 public immutable OFFER_START;
    uint256 public immutable OFFER_END;
    uint256 public immutable WEIGHT_SCALE;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    bool public isOfferTokensDeposited;

    mapping(address account => uint256 spentAmount) public offerUsage;
    uint256 public claimantCount;

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
        if (offerDuration == 0) revert OfferDurationIsZero();
        OFFER_START = offerStart;
        OFFER_END = offerStart + offerDuration;

        // register an org
        HUB.registerOrganization(orgName, 0);
        for (uint256 i; i < acceptedCRC.length;) {
            HUB.trust(acceptedCRC[i], type(uint96).max);
            unchecked {
                ++i;
            }
        }
    }

    function isOfferAvailable() external view returns (bool) {
        return OFFER_START <= block.timestamp && OFFER_END >= block.timestamp && isOfferTokensDeposited;
    }

    function isAccountEligible(address account) external view returns (bool) {
        return ACCOUNT_WEIGHT_PROVIDER.getAccountWeight(account) > 0;
    }

    function getTotalEligibleAccounts() external view returns (uint256) {
        return ACCOUNT_WEIGHT_PROVIDER.getTotalAccounts();
    }

    function getAccountOfferLimit(address account) public view returns (uint256) {
        return BASE_OFFER_LIMIT_IN_CRC * ACCOUNT_WEIGHT_PROVIDER.getAccountWeight(account) / WEIGHT_SCALE;
    }

    function getAvailableAccountOfferLimit(address account) external view returns (uint256) {
        return getAccountOfferLimit(account) - offerUsage[account];
    }

    function getRequiredOfferTokenAmount() public view returns (uint256) {
        return
            (BASE_OFFER_LIMIT_IN_CRC * ACCOUNT_WEIGHT_PROVIDER.getTotalWeight()) / (WEIGHT_SCALE * TOKEN_PRICE_IN_CRC);
    }

    /// requires token pre-approval
    function depositOfferTokens() external onlyOwner {
        // Q: should it be allowed to deposit after offer start?
        //if (block.timestamp > OFFER_START) revert OfferDepositClosed();
        if (isOfferTokensDeposited) revert OfferDepositClosed();

        // token amount

        uint256 amount = getRequiredOfferTokenAmount();

        // freeze weight provider
        ACCOUNT_WEIGHT_PROVIDER.finalizeWeights();

        // receieve token
        TOKEN.safeTransferFrom(OWNER, address(this), amount);

        isOfferTokensDeposited = true;

        emit OfferTokensDeposited(amount);
    }

    function withdrawUnclaimedOfferTokens() external onlyOwner returns (uint256 balance) {
        if (OFFER_END > block.timestamp) revert OfferActive();
        balance = TOKEN.balanceOf(address(this));
        if (balance > 0) TOKEN.safeTransfer(OWNER, balance);
    }

    function _claimOffer(address account, uint256 value) internal returns (uint256 amount) {
        uint256 accountLimit = getAccountOfferLimit(account);

        if (accountLimit == 0) revert IneligibleAccount(account);

        uint256 availableLimit = accountLimit - offerUsage[account];
        if (availableLimit == accountLimit) ++claimantCount;
        if (availableLimit < value) revert ExceedsOfferLimit(availableLimit, value);

        offerUsage[account] += value;

        // transfer token
        amount = value * (10 ** TOKEN_DECIMALS) / TOKEN_PRICE_IN_CRC;
        TOKEN.safeTransfer(account, amount);

        emit OfferClaimed(account, value, amount);
    }

    // callback

    function onERC1155Received(address, /*operator*/ address from, uint256 id, uint256 value, bytes memory data)
        external
        onlyHub
        onlyWhenOfferTokensDeposited
        onlyWhileOfferActive
        returns (bytes4)
    {
        if (!HUB.isTrusted(address(this), address(uint160(id)))) revert InvalidTokenId(id);
        if (CREATED_BY_CYCLE && from != OWNER) revert OnlyFromCycle();
        if (CREATED_BY_CYCLE) from = abi.decode(data, (address));

        uint256 amount = _claimOffer(from, value);
        data = CREATED_BY_CYCLE ? abi.encode(from, amount) : new bytes(0);

        // transfer to owner
        HUB.safeTransferFrom(address(this), OWNER, id, value, data);

        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address, /*operator*/
        address from,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) external onlyHub onlyWhenOfferTokensDeposited onlyWhileOfferActive returns (bytes4) {
        uint256 totalValue;
        for (uint256 i; i < ids.length; i++) {
            if (!HUB.isTrusted(address(this), address(uint160(ids[i])))) revert InvalidTokenId(ids[i]);
            totalValue += values[i];
            unchecked {
                ++i;
            }
        }
        if (CREATED_BY_CYCLE && from != OWNER) revert OnlyFromCycle();
        if (CREATED_BY_CYCLE) from = abi.decode(data, (address));
        uint256 amount = _claimOffer(from, totalValue);
        data = CREATED_BY_CYCLE ? abi.encode(from, amount) : new bytes(0);

        // transfer to owner
        HUB.safeBatchTransferFrom(address(this), OWNER, ids, values, data);

        return this.onERC1155BatchReceived.selector;
    }
}
