// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IERC20.sol";
import "./IERC8004.sol";

/**
 * @title AevumPayVault - Autonomous Agentic Payables & Settlement Protocol
 * @notice Designed for Aevum Testnet (Chain ID 44005) using tUSD8 stablecoin.
 *         Enforces scoped session keys, daily spending velocity caps, ERC-8004
 *         Confirmation of Payee checks, and 1-click emergency revocation.
 */
contract AevumPayVault is IERC8004 {
    address public immutable owner;
    IERC20 public immutable tUSD8;

    struct SessionKeyConfig {
        uint256 maxPerTx;       // Max tUSD8 allowed per individual transaction (in wei/decimals)
        uint256 dailyLimit;     // Max tUSD8 allowed per 24-hour epoch
        uint256 spentToday;     // Accumulated spend in current epoch
        uint256 epochStart;     // Timestamp of current 24-hour epoch start
        uint256 expiry;         // Timestamp after which session key is invalid
        bool isActive;          // Master revocation toggle
    }

    // Mapping: Session Key Address => Configuration & Velocity State
    mapping(address => SessionKeyConfig) public sessionKeys;

    // Mapping: Payee Address => ERC-8004 Profile
    mapping(address => PayeeProfile) private payees;

    // Custom Errors for Gas Optimization & Clear Diagnostics
    error Unauthorized();
    error SessionKeyInactive();
    error SessionKeyExpired();
    error ExceedsPerTxLimit(uint256 requested, uint256 maxAllowed);
    error ExceedsDailyLimit(uint256 requested, uint256 remainingToday);
    error PayeeNotVerified(address payee, PayeeStatus status);
    error InsufficientVaultBalance(uint256 requested, uint256 available);
    error TransferFailed();

    // Events for Auditability & Real-Time Indexing
    event SessionKeyAuthorized(address indexed agentKey, uint256 maxPerTx, uint256 dailyLimit, uint256 expiry);
    event SessionKeyRevoked(address indexed agentKey, string reason);
    event AgentPaymentDispatched(
        address indexed agentKey,
        address indexed payee,
        bytes32 indexed invoiceHash,
        uint256 amount,
        uint256 remainingDailyBudget
    );
    event EmergencyHaltTriggered(address indexed triggeredBy, uint256 timestamp);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _tUSD8Address) {
        owner = msg.sender;
        tUSD8 = IERC20(_tUSD8Address);
    }

    // =========================================================================
    // 1. SESSION KEY LIFECYCLE MANAGEMENT (HUMAN OWNER CONTROLS)
    // =========================================================================

    /**
     * @notice Delegates a scoped session key to an autonomous AI agent daemon.
     * @param agentKey Public address of the AI agent's dedicated transaction signer.
     * @param maxPerTx Ceiling for any single invoice settlement.
     * @param dailyLimit Cumulative 24-hour spending velocity cap.
     * @param durationSeconds Validity window from current block timestamp.
     */
    function authorizeSessionKey(
        address agentKey,
        uint256 maxPerTx,
        uint256 dailyLimit,
        uint256 durationSeconds
    ) external onlyOwner {
        require(agentKey != address(0), "Invalid agent address");
        require(maxPerTx <= dailyLimit, "Per-tx cap exceeds daily budget");

        sessionKeys[agentKey] = SessionKeyConfig({
            maxPerTx: maxPerTx,
            dailyLimit: dailyLimit,
            spentToday: 0,
            epochStart: block.timestamp,
            expiry: block.timestamp + durationSeconds,
            isActive: true
        });

        emit SessionKeyAuthorized(agentKey, maxPerTx, dailyLimit, block.timestamp + durationSeconds);
    }

    /**
     * @notice Instantly revokes an agent's authorization (Emergency Kill-Switch).
     */
    function revokeSessionKey(address agentKey, string calldata reason) external onlyOwner {
        sessionKeys[agentKey].isActive = false;
        emit SessionKeyRevoked(agentKey, reason);
    }

    // =========================================================================
    // 2. AUTONOMOUS AGENT PAYMENT DISPATCH (AGENT INTERACTION)
    // =========================================================================

    /**
     * @notice Invoked autonomously by the AI agent to settle a verified invoice.
     * @param payee Recipient address registered under ERC-8004.
     * @param amount Stablecoin amount in tUSD8.
     * @param invoiceHash Cryptographic hash (SHA-256) of the validated invoice payload.
     */
    function executeAgentPayment(
        address payee,
        uint256 amount,
        bytes32 invoiceHash
    ) external returns (bool) {
        SessionKeyConfig storage config = sessionKeys[msg.sender];

        // 1. Validate Session Key Liveness
        if (!config.isActive) revert SessionKeyInactive();
        if (block.timestamp >= config.expiry) revert SessionKeyExpired();

        // 2. Enforce Per-Transaction Scoped Limit
        if (amount > config.maxPerTx) {
            revert ExceedsPerTxLimit(amount, config.maxPerTx);
        }

        // 3. Roll 24-Hour Epoch if Window Has Elapsed
        if (block.timestamp >= config.epochStart + 1 days) {
            config.epochStart = block.timestamp;
            config.spentToday = 0;
        }

        // 4. Enforce Cumulative Daily Velocity Limit
        if (config.spentToday + amount > config.dailyLimit) {
            revert ExceedsDailyLimit(amount, config.dailyLimit - config.spentToday);
        }

        // 5. Enforce ERC-8004 Confirmation of Payee Check
        PayeeProfile memory profile = payees[payee];
        if (profile.status != PayeeStatus.VERIFIED) {
            revert PayeeNotVerified(payee, profile.status);
        }

        // 6. Check Vault Balance
        uint256 vaultBalance = tUSD8.balanceOf(address(this));
        if (vaultBalance < amount) {
            revert InsufficientVaultBalance(amount, vaultBalance);
        }

        // 7. Mutate State Before External Call (Checks-Effects-Interactions)
        config.spentToday += amount;

        // 8. Execute Stablecoin Transfer
        bool success = tUSD8.transfer(payee, amount);
        if (!success) revert TransferFailed();

        emit PaymentVerified(payee, invoiceHash, amount);
        emit AgentPaymentDispatched(
            msg.sender,
            payee,
            invoiceHash,
            amount,
            config.dailyLimit - config.spentToday
        );

        return true;
    }

    // =========================================================================
    // 3. ERC-8004 CONFIRMATION OF PAYEE REGISTRY
    // =========================================================================

    function registerPayee(
        string calldata legalOrAgentName,
        string calldata endpointUri,
        bytes32 proofHash
    ) external override {
        payees[msg.sender] = PayeeProfile({
            legalOrAgentName: legalOrAgentName,
            endpointUri: endpointUri,
            status: PayeeStatus.VERIFIED,
            registeredAt: block.timestamp,
            verificationProofHash: proofHash
        });

        emit PayeeRegistered(msg.sender, legalOrAgentName, proofHash);
    }

    function setPayeeStatus(address payee, PayeeStatus status) external override onlyOwner {
        payees[payee].status = status;
        emit PayeeStatusUpdated(payee, status);
    }

    function getPayeeProfile(address payee) external view override returns (PayeeProfile memory) {
        return payees[payee];
    }

    function verifyPayee(address payee, bytes32 invoiceHash) external view override returns (bool isVerified) {
        return payees[payee].status == PayeeStatus.VERIFIED && invoiceHash != bytes32(0);
    }

    // =========================================================================
    // 4. TREASURY EMERGENCY WITHDRAWAL
    // =========================================================================

    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        require(tUSD8.transfer(to, amount), "Emergency withdraw failed");
    }
}
