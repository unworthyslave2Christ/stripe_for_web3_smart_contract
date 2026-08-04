// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Web3 Billing Protocol
/// @author Your Company
/// @notice Account Abstraction-native recurring billing infrastructure.
/// @dev
/// This protocol stores billing state only.
/// Payment execution is delegated to ERC-4337 smart accounts,
/// session keys, billing operators and off-chain workers.
contract Web3BillingProtocol is Ownable, Pausable {
    ////////////////////////////////////////////////////////////
    //                     PROTOCOL INFO
    ////////////////////////////////////////////////////////////

    string public constant VERSION = "1.0.0";

    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint16 public constant MAX_PROTOCOL_FEE_BPS = 1000;

    ////////////////////////////////////////////////////////////
    //                        ENUMS
    ////////////////////////////////////////////////////////////

    enum MerchantStatus {
        ACTIVE,
        PAUSED,
        DISABLED,
        ARCHIVED
    }

    enum PlanStatus {
        ACTIVE,
        PAUSED,
        ARCHIVED
    }

    enum SubscriptionStatus {
        ACTIVE,
        PAUSED,
        CANCELLED
    }

    enum BillingResult {
        SUCCESS,
        FAILED,
        SKIPPED
    }

    ////////////////////////////////////////////////////////////
    //                    CUSTOM ERRORS
    ////////////////////////////////////////////////////////////

    error Unauthorized();

    error InvalidAddress();

    error InvalidAmount();

    error InvalidInterval();

    error InvalidFee();

    error MerchantAlreadyExists();

    error MerchantNotFound();

    error MerchantInactive();

    error PlanNotFound();

    error PlanInactive();

    error SubscriptionNotFound();

    error SubscriptionInactive();

    ////////////////////////////////////////////////////////////
    //                     MERCHANTS
    ////////////////////////////////////////////////////////////

    struct Merchant {


        /// Internal protocol identifier.
        uint256 id;

        /// Merchant Account Abstraction wallet.
        /// This wallet owns protocol operations.
        address smartAccount;

        /// Wallet receiving settlements.
        address payoutWallet;

        /// Merchant display name.
        string name;

        /// Optional metadata.
        string metadataURI;

        MerchantStatus status;

        uint64 createdAt;

        uint64 updatedAt;
    }

    ////////////////////////////////////////////////////////////
    //                        PLANS
    ////////////////////////////////////////////////////////////

    struct Plan {


        uint256 id;

        uint256 merchantId;

        address paymentToken;

        uint256 amount;

        uint256 billingInterval;

        string name;

        PlanStatus status;

        uint64 createdAt;

        uint64 updatedAt;

        uint64 trialPeriod;

        uint32 maxSubscribers;

        bool allowRenewal;
    }

    ////////////////////////////////////////////////////////////
    //                   SUBSCRIPTIONS
    ////////////////////////////////////////////////////////////

    struct Subscription {


        uint256 id;

        uint256 planId;

        /// EOA that created subscription.
        address subscriber;

        /// ERC-4337 smart account.
        address smartAccount;

        /**
         * Permission identifier produced by the
         * Account Abstraction layer.
         *
         * The protocol intentionally treats this
         * as an opaque identifier.
         *
         * Session keys / validators remain off-chain.
         */
        bytes32 permissionId;

        uint64 createdAt;

        uint64 cancelledAt;

        uint64 lastChargedAt;

        uint64 nextBillingTime;

        SubscriptionStatus status;
    }

    ////////////////////////////////////////////////////////////
    //                  BILLING HISTORY
    ////////////////////////////////////////////////////////////

    struct BillingRecord {


        uint256 subscriptionId;

        uint256 amount;

        uint256 protocolFee;

        uint64 timestamp;

        BillingResult result;

        /// ERC-4337 UserOperation hash.
        bytes32 userOperationHash;
    }

    ////////////////////////////////////////////////////////////
    //                 PRIMARY STORAGE
    ////////////////////////////////////////////////////////////

    uint256 private _nextMerchantId = 1;

    uint256 private _nextPlanId = 1;

    uint256 private _nextSubscriptionId = 1;

    mapping(uint256 => Merchant) private _merchants;

    mapping(uint256 => Plan) private _plans;

    mapping(uint256 => Subscription) private _subscriptions;

    ////////////////////////////////////////////////////////////
    //                SECONDARY INDEXES
    ////////////////////////////////////////////////////////////

    /// Smart Account => Merchant
    mapping(address => uint256) public merchantBySmartAccount;

    /// Merchant => Plans
    mapping(uint256 => uint256[]) private _merchantPlans;

    /// Plan => Subscriptions
    mapping(uint256 => uint256[]) private _planSubscriptions;

    /// Subscriber => Subscriptions
    mapping(address => uint256[]) private _subscriberSubscriptions;

    ////////////////////////////////////////////////////////////
    //                 BILLING STORAGE
    ////////////////////////////////////////////////////////////

    mapping(uint256 => BillingRecord[]) private _billingHistory;

    ////////////////////////////////////////////////////////////
    //               BILLING OPERATORS
    ////////////////////////////////////////////////////////////

    /**
     * merchantId
     *      ↓
     * operator
     *      ↓
     * approved
     */
    mapping(uint256 => mapping(address => bool)) public billingOperators;

    ////////////////////////////////////////////////////////////
    //               PROTOCOL SETTINGS
    ////////////////////////////////////////////////////////////

    /// Receives protocol revenue.
    address public protocolTreasury;

    /// Basis points charged per successful billing.
    uint16 public protocolFeeBps;

    ////////////////////////////////////////////////////////////
    //                         EVENTS
    ////////////////////////////////////////////////////////////

    event MerchantCreated(
        uint256 indexed merchantId, address indexed smartAccount, address indexed payoutWallet, string name
    );

    event MerchantUpdated(uint256 indexed merchantId);

    event MerchantStatusChanged(uint256 indexed merchantId, MerchantStatus status);

    event PlanCreated(uint256 indexed merchantId, uint256 indexed planId);

    event PlanUpdated(uint256 indexed planId);

    event PlanStatusChanged(uint256 indexed planId, PlanStatus status);

    event SubscriptionCreated(uint256 indexed subscriptionId, uint256 indexed planId, address indexed subscriber);

    event SubscriptionCancelled(uint256 indexed subscriptionId);

    event BillingCompleted(uint256 indexed subscriptionId, uint256 amount, uint256 protocolFee);

    event BillingFailed(uint256 indexed subscriptionId);

    event BillingOperatorApproved(uint256 indexed merchantId, address indexed operator);

    event BillingOperatorRevoked(uint256 indexed merchantId, address indexed operator);

    event ProtocolFeeUpdated(uint16 previousFee, uint16 newFee);

    event ProtocolTreasuryUpdated(address previousTreasury, address newTreasury);

    ////////////////////////////////////////////////////////////
    //                      CONSTRUCTOR
    ////////////////////////////////////////////////////////////

    constructor(address treasury, uint16 feeBps) Ownable(msg.sender) {
        if (treasury == address(0)) {
            revert InvalidAddress();
        }

        if (feeBps > MAX_PROTOCOL_FEE_BPS) {
            revert InvalidFee();
        }

        protocolTreasury = treasury;
        protocolFeeBps = feeBps;
    }

    ////////////////////////////////////////////////////////////
    //                 PROTOCOL ADMINISTRATION
    ////////////////////////////////////////////////////////////

    function updateProtocolFee(uint16 newFee) external onlyOwner {
        if (newFee > MAX_PROTOCOL_FEE_BPS) {
            revert InvalidFee();
        }

        emit ProtocolFeeUpdated(protocolFeeBps, newFee);

        protocolFeeBps = newFee;
    }

    function updateProtocolTreasury(address treasury) external onlyOwner {
        if (treasury == address(0)) {
            revert InvalidAddress();
        }

        emit ProtocolTreasuryUpdated(protocolTreasury, treasury);

        protocolTreasury = treasury;
    }

    ////////////////////////////////////////////////////////////
    //               GLOBAL PAUSE CONTROLS
    ////////////////////////////////////////////////////////////

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    ////////////////////////////////////////////////////////////
    //              INTERNAL VALIDATION HELPERS
    ////////////////////////////////////////////////////////////

    function _merchant(uint256 merchantId) internal view returns (Merchant storage merchant) {
        merchant = _merchants[merchantId];

        if (merchant.id == 0) {
            revert MerchantNotFound();
        }
    }

    function _plan(uint256 planId) internal view returns (Plan storage plan) {
        plan = _plans[planId];

        if (plan.id == 0) {
            revert PlanNotFound();
        }
    }

    function _subscription(uint256 subscriptionId) internal view returns (Subscription storage subscription) {
        subscription = _subscriptions[subscriptionId];

        if (subscription.id == 0) {
            revert SubscriptionNotFound();
        }
    }

    ////////////////////////////////////////////////////////////
    //                     ACCESS CONTROL
    ////////////////////////////////////////////////////////////

    modifier onlyMerchant(uint256 merchantId) {
        Merchant storage merchant = _merchant(merchantId);

        if (merchant.smartAccount != msg.sender) {
            revert Unauthorized();
        }

        _;
    }

    modifier onlyPlanMerchant(uint256 planId) {
        Plan storage plan = _plan(planId);

        Merchant storage merchant = _merchant(plan.merchantId);

        if (merchant.smartAccount != msg.sender) {
            revert Unauthorized();
        }

        _;
    }

    modifier onlySubscriber(uint256 subscriptionId) {
        Subscription storage subscription = _subscription(subscriptionId);

        if (subscription.subscriber != msg.sender) {
            revert Unauthorized();
        }

        _;
    }

    ////////////////////////////////////////////////////////////
    //               BILLING AUTHORIZATION
    ////////////////////////////////////////////////////////////

    /**
     * @notice Restricts execution to the merchant smart account
     *         or an approved billing operator.
     *
     * This allows merchants to:
     *  - run billing directly from their smart account, or
     *  - delegate recurring billing to an off-chain worker
     *    without giving away ownership of the account.
     *
     * Future versions may replace billing operators with
     * ERC-7579 session keys while keeping this external API.
     */
    modifier onlyBillingExecutor(uint256 subscriptionId) {
        Subscription storage subscription = _subscription(subscriptionId);

        Plan storage plan = _plan(subscription.planId);

        Merchant storage merchant = _merchant(plan.merchantId);

        bool authorized = msg.sender == merchant.smartAccount || billingOperators[merchant.id][msg.sender];

        if (!authorized) {
            revert Unauthorized();
        }

        _;
    }
    ////////////////////////////////////////////////////////////
    //               MERCHANT REGISTRATION
    ////////////////////////////////////////////////////////////

    function registerMerchant(
        address smartAccount,
        address payoutWallet,
        string calldata name,
        string calldata metadataURI
    ) external whenNotPaused returns (uint256 merchantId) {
        if (smartAccount == address(0)) {
            revert InvalidAddress();
        }

        if (payoutWallet == address(0)) {
            revert InvalidAddress();
        }

        if (merchantBySmartAccount[smartAccount] != 0) {
            revert MerchantAlreadyExists();
        }

        merchantId = _nextMerchantId++;

        Merchant storage merchant = _merchants[merchantId];

        merchant.id = merchantId;
        merchant.smartAccount = smartAccount;
        merchant.payoutWallet = payoutWallet;
        merchant.name = name;
        merchant.metadataURI = metadataURI;
        merchant.status = MerchantStatus.ACTIVE;
        merchant.createdAt = uint64(block.timestamp);
        merchant.updatedAt = uint64(block.timestamp);

        merchantBySmartAccount[smartAccount] = merchantId;

        emit MerchantCreated(merchantId, smartAccount, payoutWallet, name);
    }

    ////////////////////////////////////////////////////////////
    //             MERCHANT PROFILE MANAGEMENT
    ////////////////////////////////////////////////////////////

    function updateMerchantProfile(uint256 merchantId, string calldata name, string calldata metadataURI)
        external
        onlyMerchant(merchantId)
    {
        Merchant storage merchant = _merchant(merchantId);

        merchant.name = name;
        merchant.metadataURI = metadataURI;
        merchant.updatedAt = uint64(block.timestamp);

        emit MerchantUpdated(merchantId);
    }

    ////////////////////////////////////////////////////////////
    //              SMART ACCOUNT MANAGEMENT
    ////////////////////////////////////////////////////////////

    function updateSmartAccount(uint256 merchantId, address newSmartAccount) external onlyMerchant(merchantId) {
        if (newSmartAccount == address(0)) {
            revert InvalidAddress();
        }

        if (merchantBySmartAccount[newSmartAccount] != 0) {
            revert MerchantAlreadyExists();
        }

        Merchant storage merchant = _merchant(merchantId);

        delete merchantBySmartAccount[merchant.smartAccount];

        merchant.smartAccount = newSmartAccount;
        merchant.updatedAt = uint64(block.timestamp);

        merchantBySmartAccount[newSmartAccount] = merchantId;

        emit MerchantUpdated(merchantId);
    }

    ////////////////////////////////////////////////////////////
    //             PAYOUT WALLET MANAGEMENT
    ////////////////////////////////////////////////////////////

    function updatePayoutWallet(uint256 merchantId, address newPayoutWallet) external onlyMerchant(merchantId) {
        if (newPayoutWallet == address(0)) {
            revert InvalidAddress();
        }

        Merchant storage merchant = _merchant(merchantId);

        merchant.payoutWallet = newPayoutWallet;

        merchant.updatedAt = uint64(block.timestamp);

        emit MerchantUpdated(merchantId);
    }

    ////////////////////////////////////////////////////////////
    //            MERCHANT STATUS MANAGEMENT
    ////////////////////////////////////////////////////////////

    function pauseMerchant(uint256 merchantId) external onlyMerchant(merchantId) {
        Merchant storage merchant = _merchant(merchantId);

        merchant.status = MerchantStatus.PAUSED;

        merchant.updatedAt = uint64(block.timestamp);

        emit MerchantStatusChanged(merchantId, MerchantStatus.PAUSED);
    }

    function activateMerchant(uint256 merchantId) external onlyMerchant(merchantId) {
        Merchant storage merchant = _merchant(merchantId);

        merchant.status = MerchantStatus.ACTIVE;

        merchant.updatedAt = uint64(block.timestamp);

        emit MerchantStatusChanged(merchantId, MerchantStatus.ACTIVE);
    }

    function disableMerchant(uint256 merchantId) external onlyOwner {
        Merchant storage merchant = _merchant(merchantId);

        merchant.status = MerchantStatus.DISABLED;

        merchant.updatedAt = uint64(block.timestamp);

        emit MerchantStatusChanged(merchantId, MerchantStatus.DISABLED);
    }

    function archiveMerchant(uint256 merchantId) external onlyMerchant(merchantId) {
        Merchant storage merchant = _merchant(merchantId);

        merchant.status = MerchantStatus.ARCHIVED;

        merchant.updatedAt = uint64(block.timestamp);

        emit MerchantStatusChanged(merchantId, MerchantStatus.ARCHIVED);
    }

    ////////////////////////////////////////////////////////////
    //          TRANSFER MERCHANT OWNERSHIP
    ////////////////////////////////////////////////////////////

    /**
     * @notice Transfers protocol ownership of a merchant
     *         to another Account Abstraction wallet.
     *
     * The payout wallet remains unchanged.
     */
    function transferMerchantOwnership(uint256 merchantId, address newSmartAccount) external onlyMerchant(merchantId) {
        if (newSmartAccount == address(0)) {
            revert InvalidAddress();
        }

        if (merchantBySmartAccount[newSmartAccount] != 0) {
            revert MerchantAlreadyExists();
        }

        Merchant storage merchant = _merchant(merchantId);

        delete merchantBySmartAccount[merchant.smartAccount];

        merchant.smartAccount = newSmartAccount;

        merchant.updatedAt = uint64(block.timestamp);

        merchantBySmartAccount[newSmartAccount] = merchantId;

        emit MerchantUpdated(merchantId);
    }

    ////////////////////////////////////////////////////////////
    //               BILLING OPERATORS
    ////////////////////////////////////////////////////////////

    /**
     * @notice Approves an off-chain billing executor.
     *
     * Examples:
     *  • Company billing worker
     *  • Session-key wallet
     *  • Automation service
     */
    function approveBillingOperator(uint256 merchantId, address operator) external onlyMerchant(merchantId) {
        if (operator == address(0)) {
            revert InvalidAddress();
        }

        billingOperators[merchantId][operator] = true;

        emit BillingOperatorApproved(merchantId, operator);
    }

    function revokeBillingOperator(uint256 merchantId, address operator) external onlyMerchant(merchantId) {
        delete billingOperators[merchantId][operator];

        emit BillingOperatorRevoked(merchantId, operator);
    }

    ////////////////////////////////////////////////////////////
    //                 MERCHANT GETTERS
    ////////////////////////////////////////////////////////////

    function getMerchant(uint256 merchantId) external view returns (Merchant memory) {
        return _merchant(merchantId);
    }

    function merchantExists(address smartAccount) external view returns (bool) {
        return merchantBySmartAccount[smartAccount] != 0;
    }

    function merchantIdOf(address smartAccount) external view returns (uint256) {
        return merchantBySmartAccount[smartAccount];
    }

    function merchantPlanCount(uint256 merchantId) external view returns (uint256) {
        return _merchantPlans[merchantId].length;
    }
    ////////////////////////////////////////////////////////////
    //                  PLAN CREATION
    ////////////////////////////////////////////////////////////

    function createPlan(
        uint256 merchantId,
        string calldata name,
        address paymentToken,
        uint256 amount,
        uint256 billingInterval
    ) external whenNotPaused onlyMerchant(merchantId) returns (uint256 planId) {
        Merchant storage merchant = _merchant(merchantId);

        if (merchant.status != MerchantStatus.ACTIVE) {
            revert MerchantInactive();
        }

        if (paymentToken == address(0)) {
            revert InvalidAddress();
        }

        if (amount == 0) {
            revert InvalidAmount();
        }

        if (billingInterval == 0) {
            revert InvalidInterval();
        }

        planId = _nextPlanId++;

        Plan storage plan = _plans[planId];

        plan.id = planId;
        plan.merchantId = merchantId;
        plan.paymentToken = paymentToken;
        plan.amount = amount;
        plan.billingInterval = billingInterval;
        plan.name = name;

        plan.status = PlanStatus.ACTIVE;

        plan.createdAt = uint64(block.timestamp);

        plan.updatedAt = uint64(block.timestamp);

        // MVP defaults
        plan.trialPeriod = 0;
        plan.maxSubscribers = 0;
        plan.allowRenewal = true;

        _merchantPlans[merchantId].push(planId);

        emit PlanCreated(merchantId, planId);
    }

    ////////////////////////////////////////////////////////////
    //                  PLAN UPDATES
    ////////////////////////////////////////////////////////////

    function updatePlanName(uint256 planId, string calldata newName) external onlyPlanMerchant(planId) {
        Plan storage plan = _plan(planId);

        plan.name = newName;

        plan.updatedAt = uint64(block.timestamp);

        emit PlanUpdated(planId);
    }

    function updatePlanAmount(uint256 planId, uint256 newAmount) external onlyPlanMerchant(planId) {
        if (newAmount == 0) {
            revert InvalidAmount();
        }

        Plan storage plan = _plan(planId);

        plan.amount = newAmount;

        plan.updatedAt = uint64(block.timestamp);

        emit PlanUpdated(planId);
    }

    function updatePlanInterval(uint256 planId, uint256 newInterval) external onlyPlanMerchant(planId) {
        if (newInterval == 0) {
            revert InvalidInterval();
        }

        Plan storage plan = _plan(planId);

        plan.billingInterval = newInterval;

        plan.updatedAt = uint64(block.timestamp);

        emit PlanUpdated(planId);
    }

    function updatePlanPaymentToken(uint256 planId, address newToken) external onlyPlanMerchant(planId) {
        if (newToken == address(0)) {
            revert InvalidAddress();
        }

        Plan storage plan = _plan(planId);

        plan.paymentToken = newToken;

        plan.updatedAt = uint64(block.timestamp);

        emit PlanUpdated(planId);
    }

    ////////////////////////////////////////////////////////////
    //             OPTIONAL PLAN FEATURES
    ////////////////////////////////////////////////////////////

    function updateTrialPeriod(uint256 planId, uint64 newTrialPeriod) external onlyPlanMerchant(planId) {
        Plan storage plan = _plan(planId);

        plan.trialPeriod = newTrialPeriod;

        plan.updatedAt = uint64(block.timestamp);

        emit PlanUpdated(planId);
    }

    function updateMaxSubscribers(uint256 planId, uint32 maxSubscribers) external onlyPlanMerchant(planId) {
        Plan storage plan = _plan(planId);

        plan.maxSubscribers = maxSubscribers;

        plan.updatedAt = uint64(block.timestamp);

        emit PlanUpdated(planId);
    }

    function setAutoRenewal(uint256 planId, bool enabled) external onlyPlanMerchant(planId) {
        Plan storage plan = _plan(planId);

        plan.allowRenewal = enabled;

        plan.updatedAt = uint64(block.timestamp);

        emit PlanUpdated(planId);
    }

    ////////////////////////////////////////////////////////////
    //                 PLAN STATUS
    ////////////////////////////////////////////////////////////

    function pausePlan(uint256 planId) external onlyPlanMerchant(planId) {
        Plan storage plan = _plan(planId);

        plan.status = PlanStatus.PAUSED;

        plan.updatedAt = uint64(block.timestamp);

        emit PlanStatusChanged(planId, PlanStatus.PAUSED);
    }

    function activatePlan(uint256 planId) external onlyPlanMerchant(planId) {
        Plan storage plan = _plan(planId);

        plan.status = PlanStatus.ACTIVE;

        plan.updatedAt = uint64(block.timestamp);

        emit PlanStatusChanged(planId, PlanStatus.ACTIVE);
    }

    function archivePlan(uint256 planId) external onlyPlanMerchant(planId) {
        Plan storage plan = _plan(planId);

        plan.status = PlanStatus.ARCHIVED;

        plan.updatedAt = uint64(block.timestamp);

        emit PlanStatusChanged(planId, PlanStatus.ARCHIVED);
    }

    ////////////////////////////////////////////////////////////
    //                  PLAN GETTERS
    ////////////////////////////////////////////////////////////

    function getPlan(uint256 planId) external view returns (Plan memory) {
        return _plan(planId);
    }

    function getMerchantPlans(uint256 merchantId) external view returns (uint256[] memory) {
        return _merchantPlans[merchantId];
    }

    function planCount(uint256 merchantId) external view returns (uint256) {
        return _merchantPlans[merchantId].length;
    }
    ////////////////////////////////////////////////////////////
    //              SUBSCRIPTION CREATION
    ////////////////////////////////////////////////////////////

    function subscribe(uint256 planId, address smartAccount, bytes32 permissionId)
        external
        whenNotPaused
        returns (uint256 subscriptionId)
    {
        Plan storage plan = _plan(planId);

        if (plan.status != PlanStatus.ACTIVE) {
            revert PlanInactive();
        }

        if (smartAccount == address(0)) {
            revert InvalidAddress();
        }

        //////////////////////////////////////////////////////
        // OPTIONAL MAX SUBSCRIBER LIMIT
        //////////////////////////////////////////////////////

        if (plan.maxSubscribers > 0 && _planSubscriptions[planId].length >= plan.maxSubscribers) {
            revert InvalidAmount();
        }

        subscriptionId = _nextSubscriptionId++;

        Subscription storage subscription = _subscriptions[subscriptionId];

        subscription.id = subscriptionId;

        subscription.planId = planId;

        subscription.subscriber = msg.sender;

        subscription.smartAccount = smartAccount;

        /**
         * Permission identifier generated
         * by Account Abstraction layer.
         *
         * The protocol does not interpret
         * this value.
         */
        subscription.permissionId = permissionId;

        subscription.createdAt = uint64(block.timestamp);

        /**
         * Billing starts immediately
         * unless a plan trial exists.
         */
        subscription.nextBillingTime = uint64(block.timestamp + plan.trialPeriod);

        subscription.status = SubscriptionStatus.ACTIVE;

        _planSubscriptions[planId].push(subscriptionId);

        _subscriberSubscriptions[msg.sender].push(subscriptionId);

        emit SubscriptionCreated(subscriptionId, planId, msg.sender);
    }

    ////////////////////////////////////////////////////////////
    //              CANCEL SUBSCRIPTION
    ////////////////////////////////////////////////////////////

    function cancelSubscription(uint256 subscriptionId) external onlySubscriber(subscriptionId) {
        Subscription storage subscription = _subscription(subscriptionId);

        if (subscription.status == SubscriptionStatus.CANCELLED) {
            revert SubscriptionInactive();
        }

        subscription.status = SubscriptionStatus.CANCELLED;

        subscription.cancelledAt = uint64(block.timestamp);

        emit SubscriptionCancelled(subscriptionId);
    }

    ////////////////////////////////////////////////////////////
    //              PAUSE SUBSCRIPTION
    ////////////////////////////////////////////////////////////

    function pauseSubscription(uint256 subscriptionId) external onlySubscriber(subscriptionId) {
        Subscription storage subscription = _subscription(subscriptionId);

        if (subscription.status != SubscriptionStatus.ACTIVE) {
            revert SubscriptionInactive();
        }

        subscription.status = SubscriptionStatus.PAUSED;
    }

    ////////////////////////////////////////////////////////////
    //              RESUME SUBSCRIPTION
    ////////////////////////////////////////////////////////////

    function resumeSubscription(uint256 subscriptionId) external onlySubscriber(subscriptionId) {
        Subscription storage subscription = _subscription(subscriptionId);

        if (subscription.status == SubscriptionStatus.CANCELLED) {
            revert SubscriptionInactive();
        }

        subscription.status = SubscriptionStatus.ACTIVE;

        /**
         * If the subscription remained paused
         * beyond its billing window, the worker
         * can immediately process it.
         */
        if (subscription.nextBillingTime < block.timestamp) {
            subscription.nextBillingTime = uint64(block.timestamp);
        }
    }

    ////////////////////////////////////////////////////////////
    //              UPDATE PERMISSION ID
    ////////////////////////////////////////////////////////////

    /**
     * @notice Updates the AA permission reference.
     *
     * Useful when:
     *
     * - a session key expires
     * - a new validator is installed
     * - merchant migrates AA infrastructure
     *
     * The protocol does not validate the permission.
     */
    function updateSubscriptionPermission(uint256 subscriptionId, bytes32 newPermissionId)
        external
        onlySubscriber(subscriptionId)
    {
        Subscription storage subscription = _subscription(subscriptionId);

        if (subscription.status == SubscriptionStatus.CANCELLED) {
            revert SubscriptionInactive();
        }

        subscription.permissionId = newPermissionId;
    }

    ////////////////////////////////////////////////////////////
    //                  COMPLETE BILLING
    ////////////////////////////////////////////////////////////

    /**
     * @notice Called after a successful ERC-4337 payment.
     *
     * The billing worker:
     *
     * 1. Creates UserOperation
     * 2. Executes token transfer through smart account
     * 3. Calls this function to advance billing state
     *
     */
    function completeBilling(uint256 subscriptionId, bytes32 userOperationHash)
        external
        onlyBillingExecutor(subscriptionId)
    {
        Subscription storage subscription = _subscription(subscriptionId);

        if (subscription.status != SubscriptionStatus.ACTIVE) {
            revert SubscriptionInactive();
        }

        Plan storage plan = _plan(subscription.planId);

        uint256 protocolFee = (uint256(protocolFeeBps) * plan.amount * uint256(IERC20(plan.paymentToken).decimals())) / BPS_DENOMINATOR;

        subscription.lastChargedAt = uint64(block.timestamp);

        subscription.nextBillingTime = uint64(block.timestamp + plan.billingInterval);

        _recordBilling(subscriptionId, plan.amount, protocolFee, BillingResult.SUCCESS, userOperationHash);

        emit BillingCompleted(subscriptionId, plan.amount, protocolFee);
    }

    ////////////////////////////////////////////////////////////
    //                  BILLING FAILURE
    ////////////////////////////////////////////////////////////

    /**
     * @notice Records failed payment attempts.
     *
     * Examples:
     *
     * - insufficient token balance
     * - expired permission
     * - failed UserOperation
     * - reverted smart account execution
     *
     */
    function recordBillingFailure(uint256 subscriptionId, bytes32 userOperationHash)
        external
        onlyBillingExecutor(subscriptionId)
    {
        Subscription storage subscription = _subscription(subscriptionId);

        Plan storage plan = _plan(subscription.planId);

        _recordBilling(subscriptionId, plan.amount, 0, BillingResult.FAILED, userOperationHash);

        emit BillingFailed(subscriptionId);
    }

    ////////////////////////////////////////////////////////////
    //              BILLING HISTORY STORAGE
    ////////////////////////////////////////////////////////////

    function _recordBilling(
        uint256 subscriptionId,
        uint256 amount,
        uint256 protocolFee,
        BillingResult result,
        bytes32 userOperationHash
    ) internal {
        _billingHistory[subscriptionId].push(
            BillingRecord({
                subscriptionId: subscriptionId,
                amount: amount,
                protocolFee: protocolFee,
                timestamp: uint64(block.timestamp),
                result: result,
                userOperationHash: userOperationHash
            })
        );
    }

    ////////////////////////////////////////////////////////////
    //              BILLING HISTORY GETTERS
    ////////////////////////////////////////////////////////////

    function getBillingHistory(uint256 subscriptionId) external view returns (BillingRecord[] memory) {
        return _billingHistory[subscriptionId];
    }

    function billingHistoryLength(uint256 subscriptionId) external view returns (uint256) {
        return _billingHistory[subscriptionId].length;
    }

    ////////////////////////////////////////////////////////////
    //              BILLING OPERATOR VIEW
    ////////////////////////////////////////////////////////////

    function isBillingOperator(uint256 merchantId, address operator) external view returns (bool) {
        return billingOperators[merchantId][operator];
    }
    ////////////////////////////////////////////////////////////
    //              SUBSCRIPTION GETTERS
    ////////////////////////////////////////////////////////////

    function getSubscription(uint256 subscriptionId) external view returns (Subscription memory) {
        return _subscription(subscriptionId);
    }

    function getSubscriberSubscriptions(address subscriber) external view returns (uint256[] memory) {
        return _subscriberSubscriptions[subscriber];
    }

    function getPlanSubscriptions(uint256 planId) external view returns (uint256[] memory) {
        return _planSubscriptions[planId];
    }

    function subscriptionCount(uint256 planId) external view returns (uint256) {
        return _planSubscriptions[planId].length;
    }

    ////////////////////////////////////////////////////////////
    //              PROTOCOL PAUSE CONTROL
    ////////////////////////////////////////////////////////////

    /**
     * @notice Emergency protocol pause.
     *
     * Used only during:
     *
     * - contract vulnerability
     * - billing worker compromise
     * - migration event
     *
     */
    function pauseProtocol() external onlyOwner {
        _pause();
    }

    function unpauseProtocol() external onlyOwner {
        _unpause();
    }

    ////////////////////////////////////////////////////////////
    //              PLAN COUNTERS
    ////////////////////////////////////////////////////////////

    function totalMerchants() external view returns (uint256) {
        return _nextMerchantId - 1;
    }

    function totalPlans() external view returns (uint256) {
        return _nextPlanId - 1;
    }

    function totalSubscriptions() external view returns (uint256) {
        return _nextSubscriptionId - 1;
    }

    ////////////////////////////////////////////////////////////
    //              DIRECT STATUS HELPERS
    ////////////////////////////////////////////////////////////

    function merchantStatus(uint256 merchantId) external view returns (MerchantStatus) {
        return _merchant(merchantId).status;
    }

    function planStatus(uint256 planId) external view returns (PlanStatus) {
        return _plan(planId).status;
    }

    function subscriptionStatus(uint256 subscriptionId) external view returns (SubscriptionStatus) {
        return _subscription(subscriptionId).status;
    }
}
