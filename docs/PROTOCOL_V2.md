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
New envelopes set `keyWrapAadVersion = 2` and bind AES-GCM AAD to the
conversation, key epoch, sender account, sender device, recipient account,
sender identity key, sender agreement key and recipient agreement key. Legacy
v1 envelopes remain readable only for migration.

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
messages before persistence. It also rejects any message whose
`aad.conversationId` does not match the conversation ID from the request body.
Clients repeat these checks independently.

## Authentication and storage

Password verification uses asynchronous scrypt behind a bounded queue. A full
session is issued only after the client decrypts its vault and signs the login
challenge. WebSocket access uses a short-lived one-use ticket. Session tokens
and invitation tokens are stored only as hashes.

The login challenge signature binds `protocol`, `serverOrigin`, `userId`,
`deviceId`, `challenge`, `issuedAtMs` and `expiresAtMs`. This prevents replay
of a valid challenge signature across server origins or stale login attempts.
Before authentication, WebSocket connections are bounded by global, per-IP,
per-window and timeout limits. The same pre-auth slot is acquired before the
HTTP upgrade, so overloaded handshakes can fail before a WebSocket object is
created.

## Key transparency

The server maintains a local append-only key-transparency log for public account
key bundles. Each entry records the account identity key, X25519 agreement key,
signature binding, device-list hash and rotation/device epochs. Entries form a
canonical SHA-256 hash chain:

```text
root[i] = SHA256(canonical({
  protocol: "secure-chat/key-transparency-root/v1",
  previousRootHash: root[i-1],
  leafHash,
  index
}))
```

Clients fetch `/v2/key-transparency`, verify every returned leaf/root link and
compare the latest statement for the contact with the directory response before
starting a new conversation. This is a self-hosted consistency mechanism, not a
claim of global key transparency: external witnesses, gossip and public
inclusion/consistency proofs remain future work.

Vault secrets and new account exports use Argon2id with parameters stored next
to the ciphertext. Legacy PBKDF2 vaults/exports are read only for automatic
migration. Server-side quotas limit message, conversation, account, daily and
instance bytes and reserve minimum free disk space.

## Security boundary and non-goals

The server sees account, membership, timing, size and IP metadata. Protocol v2
does not provide Double Ratchet/PQXDH, post-compromise security, metadata
anonymity, OPAQUE or malicious-server equivocation resistance beyond the local
key-transparency hash chain. Until reviewed implementations of those properties
exist, the product remains an alpha and must not be described as suitable for
high-risk users.

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
