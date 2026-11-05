# Keychain migration for background recovery while the Mac is locked (macOS)

This fix targets an observed recovery failure: after the watchdog stopped the old
tunnel, the user Keychain was still locked, and the next four SecureStore reads
all returned OSStatus `-25308`. It does not explain the network failure the
watchdog first detected, and it does not promise recovery on every network path.

`flutter_secure_storage_macos 3.1.3` adds the accessibility attribute to its read,
existence-check and write queries. Merely switching the Dart options would make
legacy `WhenUnlocked` items look nonexistent and could collide on the same primary
key at write time. The migration first queries the attributes with the same
service/account, then updates the accessibility in place.

## Scope and failure boundaries

- macOS only, the seven existing SecureStore accounts. The service is fixed to
  `flutter_secure_storage_service`; class is generic password, synchronizable=false,
  Data Protection=true. The initial lookup keeps the plugin's existing default
  access-group boundary; multiple matches are rejected, and the update is bound to
  the same group that was actually returned.
- Values are never requested, read, exported or rewritten, and items are never
  deleted and recreated. Entitlements, access groups, ACLs and the Keychain
  on-disk format are untouched. The only attribute updated is
  `AfterFirstUnlockThisDeviceOnly`.
- Only legacy `WhenUnlocked` and the target accessibility are accepted. Unknown
  returned attributes, a different identity, a different group and a non-default
  access control are all rejected. When an access-control object is present, a
  no-flags object with the same accessibility is created through public API and
  compared with `CFEqual`; no private constraint-parsing API is used.
- Security APIs run with `LAContext.interactionNotAllowed=true`, so no
  authentication prompt appears. Only `errSecItemNotFound` means "absent"; errors
  such as `-25308` fail as-is. A legacy item that is inaccessible during the first
  migration needs the user to unlock normally and retry.
- All 18 CRUD entry points on macOS share a success barrier and only receive new
  options after the migration succeeds. A failure is not treated as null, does not
  fall back to the old in-RAM lease/contract, and does not weaken signature,
  expiry or sequence checks. Ordinary reads still hit the Keychain every time.
- A caller waits at most 10 seconds. A timeout does not cancel the native
  operation or clear the still-running shared Future; the next call waits on the
  same operation, and only a real native failure allows a retry. A late success
  does not run a CRUD call that has already timed out. Non-macOS platforms never
  call the migration.
- `AfterFirstUnlockThisDeviceOnly` is for background access after the first unlock
  on this machine. It does not promise availability after a reboot before the
  first unlock, and it does not migrate to another device through backups.

## Minimal receipt and explicit rollback

The default directory is `Aurora-KeychainMigration` (0700) under the current user's
Application Support. `receipt.json` (0600) records only the schema/service and,
for each of the seven accounts, the original accessibility and access group. The
schema fixes class/sync/DP; it stores no value, token, value hash or whole
attribute dictionary.

An advisory lock in the same directory serializes the migration and the
maintenance rollback. Only regular private files owned by the current user are
accepted; symlinks, hard links, non-private permissions and oversized or corrupt
receipts are rejected. The original receipt is saved through a private temp file,
file fsync, non-overwriting atomic publication and directory fsync, so any failure
happens before the first Keychain modification. An existing receipt must also pass
the persistence checks before continuing. A partially failed migration keeps its
original plan; a retry re-checks item by item and continues, never overwriting
the recorded original attributes.

The maintenance entry point lives in the real `AppDelegate.main()` and runs before
`NSApplicationMain`, the main window and the Flutter engine exist. **There is no
Flutter rollback method, no rollback at default startup, and no automatic
downgrade.** Using a signed app executable that contains this fix, run it
explicitly from that logged-in user's normal graphical Terminal:

```bash
"/Applications/aurora.app/Contents/MacOS/aurora" \
  --rollback-keychain-accessibility --confirm-aurora-stopped
```

First quit every Aurora GUI, stop the Aurora VPN, and do not reopen the app during
maintenance. The command itself does not stop or start anything: it holds the same
receipt lock, confirms twice (through read-only system VPN preferences) that its
own provider is disconnected/invalid, and confirms after each asynchronous read
that no other GUI of the same bundle is running, before invoking the native
rollback. Arguments must match exactly; extra arguments such as `--start-vpn` are
rejected. Only exit 0 with `KEYCHAIN_ROLLBACK_COMPLETE` means done; a refusal
returns exit 1 and the fixed `KEYCHAIN_ROLLBACK_REFUSED`, printing no path,
attribute or value. A hang or an external interruption is never "done": keep the
app and the receipt, verify, then decide.

Rollback convention when installing: if the new app has already migrated
SecureStore, **first run the rollback above with the still-available new signed
app, then switch back to the old app**. If the command did not succeed, do not
restore only the old binary and call it a rollback; keep a private backup of the
app and the receipt and handle the failure. Do not substitute an unsigned SSH
tool, a sudo user switch or a different access group for the original signed
access context. No secret needs to be exported to any helper.

The rollback only restores items that the receipt proves had the legacy
accessibility. Fixed accounts that did not exist before the migration and were
written later by the new version are also set back to the legacy attribute, to
keep the new value readable by the old version. Items that already had the target
accessibility are not downgraded. Missing items are not recreated, and any
unknown identity or attribute stops the rollback. Rollback is idempotent, keeps the
receipt, and deletes no secret or restores any historical old value. If the
receipt shows items that already had the target accessibility before migration,
they are not part of this change, and a successful rollback does not mean the old
plugin can read them; use a compatible version rather than arbitrarily lowering
their protection. **Simply swapping the old app back is not a rollback**, because
the old plugin still queries by the legacy accessibility: finish the attribute
rollback first, or return to a compatible version that also supports the new
attribute.

If the process crashes during receipt publication, the leftover file or link makes
later runs refuse to continue rather than guess a repair; a maintainer should
inspect the private metadata and then act. Do not delete the receipt to get past
the error.

## Reproducible verification

### Read-only compatibility check against the original signed app

Call the real signed app executable that contains this fix directly from a normal
graphical Terminal:

```bash
"/path/to/aurora.app/Contents/MacOS/aurora" --check-keychain-accessibility
```

This is a synchronous, standalone `AppDelegate.main()` branch that returns before
`NSApplicationMain`. It lets an old GUI/VPN keep running (no downtime needed) and
starts no candidate GUI or VPN. For the seven fixed accounts only, it performs the
same attribute observation and default access-control checks as `prepare`/rollback.
It reads no value, runs no `SecItemUpdate/Add/Delete`, does not construct, read or
write a receipt, and creates no directory and changes no permission. Approximate
options, repeated options and any extra argument are rejected before Security is
called.

When all seven observations succeed and the three counts sum to seven, it exits 0
with stdout `KEYCHAIN_ACCESSIBILITY_COMPATIBLE legacy=N background=N absent=N`.
Authentication being forbidden returns exit 2 and stderr
`KEYCHAIN_ACCESSIBILITY_LOCKED`; any other refusal returns exit 3 and stderr
`KEYCHAIN_ACCESSIBILITY_REFUSED reason=...`. The reason is one of the fixed values
`arguments`, `shape`, `identity`, `group`, `accessibility`, `access-control`,
`result-type`, `multiple-matches`, `unknown-attributes`, `security` or
`unexpected`; a Security error additionally returns the public numeric
`status=...`. A refusal prints no partial counts, raw exception, account, group
value, attribute or value. The classification only splits the original refusal
criteria in the same order; it does not loosen the unknown-attribute check or
`CFEqual`, and ordinary GUI error messages are unchanged. Callers should apply an
external 30-second budget; a timeout counts as incomplete, never as a pass.

`unknown-attributes` additionally returns `schema=...`, mapped only from whether
keys outside the allowlist match official Security constants, to one of the fixed
values `generic`, `invisible`, `negative`, `creator`, `type`, `token-id`,
`legacy-access`, `application-label`, `application-tag`, `permanent`. Any other key
is labelled `unrecognized-present`; the result is de-duplicated and printed in
lexicographic order. The classifier looks only at key presence, never at those
attributes' values, and prints no raw key, key hash or whole dictionary. These
categories are still always refused: being a public constant does not make
migration allowed.

The result is a snapshot of attribute compatibility at query time; even when all
seven items are absent it prints `absent=7`. It does not prove that values are
readable, that the default ACL is readable while locked, or that in-place
migration or rollback succeeded, and it does not replace later migration/rollback
verification on a real machine. An active old GUI may keep changing data, so
re-check before installing and follow the rollback procedure.

From the repository root:

```bash
bash app/macos/Runner/test/keychain/run.sh
cd app
flutter test test/secure_store_test.dart
flutter analyze lib/data/secure_store.dart test/secure_store_test.dart
```

The Swift script compiles the production `AuroraKeychainMigration.swift` directly
and uses a strict Security API double to verify the queries actually issued, the
scope of updates, read-back and the order of failures. It also uses a real receipt
store in a random temp directory to check permissions, non-overwriting, locking,
corrupt data and symlinks. The public Security access-control object tests do not
read the Keychain. The Dart tests run the real SecureStore and control native
asynchronous results, storage messages and time at the platform-message boundary.
The entry-point checks use the real Apple SDK and the actual main-entry source,
replacing only the Flutter/AppKit entry and the Security user-data boundary: they
create no GUI and query no real Aurora namespace on the test machine. The
result-type scenario injects a wrong type at the Security adapter boundary; it
verifies the error output and does not prove that real Security returns that type.
None of these tests stands in for real Data Protection, signing, lock-screen or
device acceptance.

A real signed fixture must verify attribute migration, value consistency, normal
CRUD, explicit rollback and access after a natural screen lock, in a random
service/account namespace. The fixture adapter must validate the random namespace
before every Security call and must never let the production default
service/account reach the real API; returned identities are mapped back to the
production logical names in memory only. Until real fixture or device results
exist, do not record this fix as accepted for lock-screen recovery.

Apple references:
[background accessibility attribute](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly),
[updating a Keychain item in place](https://developer.apple.com/documentation/security/updating-and-deleting-keychain-items).
Raw field logs are kept only in a private `build/verification` directory and are
not under version control.
