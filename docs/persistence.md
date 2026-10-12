# Optional Rails intent persistence

This foundation stores one immutable request envelope per submission intent, with tenant/environment/source identity, source acknowledgment, attempt state and initial response. It does not yet store the complete per-document validation history, artifacts or financial records. It makes no provider requests by itself.

Verified with Ruby3.0.3, Rails/ActiveRecord7.0.10, PostgreSQL11 and the host's Plugins and state_machines-activerecord gems. The ordinary connector depends only on Faraday; applications activating persistence must supply these additional dependencies. Plugins currently comes from the organization's existing host dependency; this is not a Rails installation that works from the connector Gemfile alone.

## Select storage before loading models

Define a named abstract ActiveRecord class in the host. For the same database, inherit the application's abstract record. For a separate database, establish the Rails database connection on that abstract class using the host's secure configuration. Credentials belong in the application's existing secret provisioning, never in this gem or its examples.

```ruby
class TaxRecord < ApplicationRecord
  self.abstract_class = true
  # Separate database: configure connects_to here using host database roles.
end

require "myinvois_connector/persistence"
MyInvoisConnector::Persistence.configure(application_record_base: "TaxRecord")
# Configure before resolving Record or SubmissionIntent; selection then freezes.
```

The optional namespaced Rails engine includes `db/migrate/20261012000000_create_lhdn_submission_intents.rb`. Install and run it against the selected store using the host's reviewed migration procedure. No migration runs automatically. Rails multi-database migration targeting still requires host installation verification; do not run an untargeted migration command against an existing application database.

## Intent lifecycle

Use `SubmissionIntent.prepare!` with an immutable `Submission`, tenant key, environment, source reference and SHA256 source digest. Store the returned UUID in the host's source reservation. A trusted source-owner role supplies `acknowledgment_for(intent)`, returning an immutable `SourceAcknowledgment` binding intent UUID, tenant, environment, source reference, source digest, request hash and reservation token.

That host role must freshly verify a committed reservation in its own store, reject calls from an open host transaction, and enforce source financial mutation protection. Web input is not an acknowledgment. This gem cannot determine whether an arbitrary host role tells the truth, whether a taxpayer is authorized, or whether a source transaction is eligible.

`acknowledge!(source_owner:)` changes awaiting_source to ready. `claim!(source_owner:)` freshly verifies the reservation and commits attempting before returning true. Claim must run outside an outer engine transaction. Only the winning caller may then send `request_bytes`, after enforcing permissions, readiness and signing/version checks. The host caller must also avoid wrapping dispatch in any source-store transaction. A false claim result does not authorize another send.

Use `record_receipt!(receipt:)` for a matching immutable submission receipt. Accepted means initial asynchronous acceptance, not Valid; all-rejected is separate. `mark_uncertain!(code:)` retains an ambiguous attempt with a safe machine code. A crash in attempting and a write timeout must be reconciled rather than blindly retried. No reset-to-ready or automatic unlock is provided. Per-document reconciliation and host dispatch remain to be implemented.

The public model API rejects identity/payload edits, direct lifecycle writes and deletion. These are application lifecycle controls, not database access controls: raw SQL, relation bulk writes and database administration can bypass callbacks. The host must keep those out of product mutation paths and restrict database access. Request bytes and identities contain sensitive business data; configure storage encryption, access and backups in the host and do not log them. Retention is permanent for now.

## Isolated integration verification

The test requires an existing host bundle supplying the dependencies above, a local PostgreSQL server on `/tmp:5432`, and an OS-matching local role allowed to create task databases. It creates two uniquely named task databases, exercises actual engine models and migrations in both storage modes, and drops only those databases on completion or error. It does not boot the host app or load its database settings.

```sh
# From a compatible host bundle; use the path to this checkout:
bundle exec ruby /path/to/einvoice-lhdn/integration/persistence_test.rb
```

Verified:11 tests/156 assertions, including two concurrent claims with one winner, mismatch/unavailable acknowledgment, outer-transaction refusal, immutable snapshots, uncertain-state no-resend, correlated receipts, retention guards, database constraints and cold model loading. Host source locking, actual migration installation, authenticated LHDN behavior and the full workflow are separate verification obligations.
