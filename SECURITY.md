# Security policy

## Supported versions

Only the latest commit on the supported release branch receives security fixes. The project is alpha software and is not approved for high-risk users.

## Reporting a vulnerability

Do not open a public issue containing exploit details, credentials, tokens, private keys, message contents, or server data. Contact the repository owner privately through the security advisory feature of the hosting platform.

Include the affected version, reproduction steps, impact, and a minimal proof of concept. Reports are acknowledged within 72 hours. Disclosure is coordinated after a fix and migration guidance are available.

## Incident response

Operators must be able to revoke all sessions, rotate update-signing and administrative credentials, restore the SQLite database from a tested backup, and notify users of identity or device-list changes. A suspected session database leak requires immediate session revocation because older deployments stored reusable session material.
