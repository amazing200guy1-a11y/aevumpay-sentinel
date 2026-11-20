// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IERC8004 - Confirmation of Payee Standard
 * @notice Provides verifiable payee identity registration, anti-spoofing checkmarks,
 *         and cryptographic invoice hash binding for autonomous agent payments on Aevum Testnet.
 */
interface IERC8004 {
    enum PayeeStatus { UNREGISTERED, VERIFIED, SUSPICIOUS, REVOKED }

    struct PayeeProfile {
        string legalOrAgentName;
        string endpointUri;
        PayeeStatus status;
        uint256 registeredAt;
        bytes32 verificationProofHash;
    }

    event PayeeRegistered(address indexed payee, string legalOrAgentName, bytes32 proofHash);
    event PayeeStatusUpdated(address indexed payee, PayeeStatus newStatus);
    event PaymentVerified(address indexed payee, bytes32 indexed invoiceHash, uint256 amount);

    function registerPayee(string calldata legalOrAgentName, string calldata endpointUri, bytes32 proofHash) external;
    function setPayeeStatus(address payee, PayeeStatus status) external;
    function getPayeeProfile(address payee) external view returns (PayeeProfile memory);
    function verifyPayee(address payee, bytes32 invoiceHash) external view returns (bool isVerified);
}
