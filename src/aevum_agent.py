"""
AevumPay Sentinel - Autonomous Accounts-Payable AI Agent Daemon
Designed for Aevum Testnet (Chain ID 44005) & QDay.io Architecture.
Provides deterministic prompt-injection screening, ERC-8004 payee lookup,
scoped session key spending enforcement, and cryptographic audit receipts.
"""

import hashlib
import json
import time
import re
from typing import Dict, Any, Tuple, Optional

# Regex heuristic patterns for invoice-borne prompt injection attacks
PROMPT_INJECTION_PATTERNS = [
    r"ignore\s+(all\s+)?(previous|prior)\s+instructions?",
    r"override\s+(daily|session|spending|tx|transaction)\s+limits?",
    r"transfer\s+(all|entire|max|everything)\s+(balance|funds|vault|treasury)",
    r"send\s+funds\s+to\s+(an?\s+)?alternative\s+address",
    r"you\s+are\s+now\s+in\s+developer\s+mode",
    r"system\s*:\s*emergency\s+admin\s+override",
    r"bypass\s+(erc-?8004|confirmation\s+of\s+payee|whitelist)",
    r"drop\s+table|delete\s+from|0x0000000000000000000000000000000000000000"
]

class InvoiceSecurityException(Exception):
    """Raised when an invoice payload fails security invariants."""
    pass

class AevumPayAgent:
    def __init__(
        self,
        agent_id: str,
        session_key_address: str,
        max_per_tx: float,
        daily_limit: float,
        expiry_timestamp: float
    ):
        self.agent_id = agent_id
        self.session_key_address = session_key_address.lower()
        self.max_per_tx = max_per_tx
        self.daily_limit = daily_limit
        self.expiry_timestamp = expiry_timestamp
        self.spent_today = 0.0
        self.epoch_start = time.time()
        self.is_active = True
        
        # Local mock of ERC-8004 Verified Payee Registry (synchronized with on-chain state)
        self.erc8004_registry: Dict[str, Dict[str, Any]] = {}
        
        # Audit log of all settled payments
        self.settlement_ledger = []

    def register_verified_payee(self, payee_address: str, name: str, endpoint_uri: str) -> None:
        """Registers a trusted vendor under ERC-8004 standard."""
        proof = hashlib.sha256(f"{name}:{payee_address}:{endpoint_uri}".encode()).hexdigest()
        self.erc8004_registry[payee_address.lower()] = {
            "name": name,
            "endpoint_uri": endpoint_uri,
            "status": "VERIFIED",
            "registered_at": time.time(),
            "proof_hash": f"0x{proof}"
        }

    def revoke_agent(self, reason: str = "Manual revocation") -> None:
        """Emergency kill-switch to immediately halt the agent."""
        self.is_active = False

    def scan_for_prompt_injection(self, text_payload: str) -> Tuple[bool, Optional[str]]:
        """
        Inspects invoice descriptions, notes, and vendor metadata for adversarial prompt injection.
        """
        normalized = text_payload.lower()
        for pattern in PROMPT_INJECTION_PATTERNS:
            match = re.search(pattern, normalized)
            if match:
                return True, match.group(0)
        return False, None

    def calculate_invoice_hash(self, invoice_data: Dict[str, Any]) -> str:
        """Computes deterministic SHA-256 fingerprint of the invoice."""
        canonical_json = json.dumps(invoice_data, sort_keys=True, separators=(',', ':'))
        return "0x" + hashlib.sha256(canonical_json.encode('utf-8')).hexdigest()

    def process_invoice(self, invoice_payload: Dict[str, Any]) -> Dict[str, Any]:
        """
        End-to-end evaluation & autonomous settlement of an incoming invoice.
        Enforces:
        1. Agent active status & session expiration.
        2. Prompt-injection defense on description/notes.
        3. ERC-8004 Confirmation of Payee verification.
        4. Scoped session key caps (per-tx & 24h rolling velocity limit).
        5. Cryptographic hash execution on Aevum Testnet (Chain ID 44005).
        """
        # 1. Check Agent Liveness
        if not self.is_active:
            raise InvoiceSecurityException("SESSION_KEY_REVOKED: Agent authorization has been revoked by vault owner.")

        if time.time() >= self.expiry_timestamp:
            raise InvoiceSecurityException("SESSION_KEY_EXPIRED: Scoped session key has passed its expiration window.")

        # 2. Inspect for Malicious Prompt Injections in Text Fields
        notes = str(invoice_payload.get("notes", ""))
        desc = str(invoice_payload.get("description", ""))
        combined_text = f"{desc} {notes}"

        has_injection, matched_pattern = self.scan_for_prompt_injection(combined_text)
        if has_injection:
            raise InvoiceSecurityException(
                f"PROMPT_INJECTION_DETECTED: Malicious instruction intercepted: '{matched_pattern}'. Execution blocked."
            )

        # 3. Verify Payee Identity under ERC-8004
        payee = str(invoice_payload.get("payee_address", "")).lower()
        if not payee or payee not in self.erc8004_registry:
            raise InvoiceSecurityException(
                f"ERC8004_UNVERIFIED_PAYEE: Address {payee} is not verified in the Confirmation of Payee registry."
            )

        payee_profile = self.erc8004_registry[payee]
        if payee_profile.get("status") != "VERIFIED":
            raise InvoiceSecurityException(
                f"ERC8004_STATUS_INVALID: Payee {payee} status is {payee_profile.get('status')}, expected VERIFIED."
            )

        # 4. Enforce Spending Limits
        amount = float(invoice_payload.get("amount_tusd8", 0.0))
        if amount <= 0:
            raise InvoiceSecurityException("INVALID_AMOUNT: Amount must be greater than zero tUSD8.")

        if amount > self.max_per_tx:
            raise InvoiceSecurityException(
                f"EXCEEDS_PER_TX_CAP: Invoice amount {amount} tUSD8 exceeds single transaction cap of {self.max_per_tx} tUSD8."
            )

        # Roll 24-hour epoch if 86,400 seconds elapsed
        if time.time() >= self.epoch_start + 86400:
            self.epoch_start = time.time()
            self.spent_today = 0.0

        if self.spent_today + amount > self.daily_limit:
            remaining = self.daily_limit - self.spent_today
            raise InvoiceSecurityException(
                f"EXCEEDS_DAILY_LIMIT: Invoice amount {amount} tUSD8 exceeds remaining 24h budget of {remaining:.2f} tUSD8."
            )

        # 5. Compute Invoice Fingerprint
        invoice_hash = self.calculate_invoice_hash(invoice_payload)

        # 6. Mutate State & Generate Synthetic Aevum Testnet TX
        self.spent_today += amount
        simulated_tx_hash = "0x" + hashlib.sha256(f"{invoice_hash}:{time.time()}:{payee}".encode()).hexdigest()

        settlement_receipt = {
            "status": "SETTLED",
            "chain_id": 44005,
            "network": "Aevum Testnet (QDay.io)",
            "token": "tUSD8",
            "amount_tusd8": amount,
            "payee_address": payee,
            "payee_name": payee_profile["name"],
            "invoice_hash": invoice_hash,
            "aevum_tx_hash": simulated_tx_hash,
            "remaining_daily_budget_tusd8": round(self.daily_limit - self.spent_today, 4),
            "settled_at": time.time(),
            "signer_agent": self.session_key_address
        }

        self.settlement_ledger.append(settlement_receipt)
        return settlement_receipt
