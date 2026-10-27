# Licensing

## Editions

| | Community | Fleet |
|---|---|---|
| Mac app, `roomy scan/clean/purge/restore/rules/doctor` | ✓ free | ✓ |
| `roomy fleet` commands (policy runs, serve, audit, metrics) | ✓ work, labelled `edition="community"` | ✓ labelled `fleet`, org and host allowance recorded |
| `roomy hub` (inventory, dashboard, managed policies, fleet metrics) | ✓ up to 5 hosts | ✓ up to the license's `maxHosts` |
| Commercial support, SLA, security contact | — | ✓ |

The free CLI is deliberately complete on a single host: adoption on servers depends on it. The paid product is operating a fleet with someone to call.

## Tokens

`ROOMY1.<base64url payload>.<base64url Ed25519 signature>`. Payload:

```json
{"id":"…","org":"Acme","edition":"fleet","maxHosts":50,"issuedAt":"…","expiresAt":"…","features":["policy","audit","metrics","serve"]}
```

Verification is **offline** against the public key compiled into `RoomyFleet/License.swift`. No network call is ever made. An expired or malformed token falls back to community with the reason shown by `roomy fleet license show` and `roomy doctor`.

Where Roomy looks, in order: the policy's `license.key`, the policy's `license.keyFile`, `/etc/roomy/license.key`, `~/.roomy/license.key`, `$ROOMY_LICENSE`.

Install one: `roomy fleet license install ROOMY1.…` (writes `~/.roomy/license.key`, mode 0600; pass `--path /etc/roomy/license.key` for system-wide).

## Issuing (vendor side)

`roomy-licensetool` is the issuer-side tool. It is not shipped and not part of the public repository; the verifier in `RoomyFleet/License.swift` is.

```sh
# once: generate the signing key pair, embed the public key in RoomyFleet/License.swift
roomy-licensetool keygen --out ~/.roomy-dev/license-signing.key

# per customer
roomy-licensetool sign --key ~/.roomy-dev/license-signing.key --org "Acme" --max-hosts 50 --days 365
roomy-licensetool verify ROOMY1.…      # against the compiled-in key
roomy-licensetool inspect ROOMY1.…     # decode without verifying
```

Keep the private key offline (a password manager or an HSM-backed file). Rotating it means a release with the new public key; existing tokens stop verifying, so issue replacements first.

`maxHosts` is recorded in audit records and metrics on every host, and **enforced by the hub**: a report from a host the hub has not seen before is refused (HTTP 402) once the inventory holds `maxHosts` hosts (5 without a license). Hosts already in the inventory keep reporting, so an expired license degrades to a warning, not an outage. The hub reads its license from `--license`, `$ROOMY_LICENSE`, `/etc/roomy/license.key` or `~/.roomy/license.key`.
