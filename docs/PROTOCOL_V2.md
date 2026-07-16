# Secure-p2p-messenger protocol v2

Status: public alpha specification. This document describes the protocol that
the client and server enforce. It is not a claim of Signal/MLS equivalence.

## Canonical encoding

Signed and hashed structures use UTF-8 JSON. Object keys are sorted
lexicographically at every nesting level; array order is preserved; no
whitespace is added. Both implementations must pass
`test-vectors/protocol-canonical-v1.json`.

## Account and device trust

The account owns an Ed25519 identity key and a signed X25519 agreement key.
Each device owns a separate Ed25519 signing key. An account identity signature
certifies the tuple `(accountId, serverOrigin, deviceId,
deviceSigningPublicKey, deviceEpoch, createdAt)`. A signed, monotonic device
list binds active certificate hashes and revoked device epochs to the account.

The server and every receiving client verify the account binding, server
origin, certificate signature, certificate age, active device-list entry and
revocation state. Identity-key replacement requires signatures by both the old
and new identity keys plus a monotonic rotation hash chain.

## Conversation keys

`memberKeys` are X25519/HKDF/AES-256-GCM envelopes signed by the sender's
account Ed25519 key. The signed data includes the conversation, key epoch,
sender account and device, recipient, embedded account keys and ciphertext.
The server binds the embedded keys to the authenticated account. The client
unwraps only with identity and agreement keys already trusted locally.

Cloud group creation and sending are disabled. They remain disabled until a
reviewed MLS deployment or an equivalent safe membership/rekey protocol is
available.

## Messages

New messages must use `secure-p2p-cloud-message/v1` with
`aad.protocolVersion = 2`. The authenticated data includes conversation and
message IDs, sender account and device, key epoch, per-device counter,
`previousMessageHash`, content type, creation time and plaintext byte count.
New clients set `aad.messageKeyDerivation = hkdf-sha256-message-v1` and derive
the AES-GCM key for each message with HKDF-SHA256 from the conversation key,
key epoch, message counter, message ID and previous message hash. This reduces
key reuse across messages, but it is not a substitute for Double Ratchet or
post-compromise security.

The device signs SHA-256 of canonical JSON:

```text
{
  "v": 1,
  "protocol": "secure-chat/device-message/v1",
  "envelope": <message without deviceCertificate and deviceSignature>
}
```

The first message of each `(conversation, sender account, sender device)`
stream uses counter 1 and the fixed genesis hash. Later messages increment the
counter by one and reference the SHA-256 hash of the complete previous message.
The server rejects legacy, replayed, forked, incorrectly signed and stale-epoch
messages before persistence. Clients repeat these checks independently.

## Authentication and storage

Password verification uses asynchronous scrypt behind a bounded queue. A full
session is issued only after the client decrypts its vault and signs the login
challenge. WebSocket access uses a short-lived one-use ticket. Session tokens
and invitation tokens are stored only as hashes.

Vault secrets and new account exports use Argon2id with parameters stored next
to the ciphertext. Legacy PBKDF2 vaults/exports are read only for automatic
migration. Server-side quotas limit message, conversation, account, daily and
instance bytes and reserve minimum free disk space.

## Security boundary and non-goals

The server sees account, membership, timing, size and IP metadata. Protocol v2
does not provide Double Ratchet/PQXDH, post-compromise security, key
transparency, metadata anonymity, OPAQUE or malicious-server equivocation
resistance. Until reviewed implementations of those properties exist, the
product remains an alpha and must not be described as suitable for high-risk
users.

## Capability gate

The current protocol version deliberately has no high-risk capability bit. A
release may only claim Double Ratchet/PQXDH, post-compromise security, key
transparency or OPAQUE/PAKE after the repository contains:

1. a reviewed protocol document for the feature,
2. an implementation based on an audited library or independently reviewed
   construction,
3. client and server tests for downgrade, rollback and equivocation cases,
4. migration tests for existing conversations and accounts.

Until then, those properties are release blockers rather than marketing claims.
