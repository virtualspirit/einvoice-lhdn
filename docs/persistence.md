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

That host role must freshly verify a committed reservation in its own store, reject calls from an open host transaction, and enforce source financial mutation protection. The reservation binding/token must be immutable and retained: no pre-attempt withdrawal or release without matching terminal provider evidence is permitted. This stability is essential because the observation occurs before the engine opens its own transaction, which may share the host connection pool. Web input is not an acknowledgment. This gem cannot determine whether an arbitrary host role tells the truth, whether a taxpayer is authorized, or whether a source transaction is eligible.

`acknowledge!(source_owner:)` changes awaiting_source to ready. `claim!(source_owner:)` freshly observes the committed reservation, opens its own intent transaction, rechecks the complete acknowledgment against the locked intent, and commits attempting before returning true. Claim must run outside an outer engine transaction. Only the winning caller may then send `request_bytes`, after enforcing permissions, readiness and signing/version checks. The host caller must also avoid wrapping dispatch in any source-store transaction. A false claim result does not authorize another send.

`MyInvoisConnector::Persistence::Dispatcher.call(intent:, client:, source_owner:)` composes this lifecycle with the explicit Client. It validates/restores the exact stored canonical envelope and document hashes, checks environment equality, claims once, sends outside both transactions and stores the correlated initial receipt. A duplicate call cannot resend attempting, accepted, rejected or uncertain work. Protocol errors retain uncertainty; if result storage also fails, attempting remains retained. Both states require reconciliation rather than resetting or blindly resending. The host must choose the correct represented taxpayer client and enforce authorization/readiness/signing before calling. No scheduler or host job is mounted automatically.

Use `record_receipt!(receipt:)` for a matching immutable initial receipt. Accepted is asynchronous acceptance, not Valid. `mark_uncertain!(code:)` retains an ambiguous attempt with a safe machine code. A crash in attempting or a timeout requires reconciliation; no reset-to-ready or automatic unlock exists. The explicit Dispatcher is implemented; host scheduling and per-document reconciliation remain pending.

The public model API rejects identity/payload edits, direct lifecycle writes and deletion. These are application lifecycle controls, not database access controls: raw SQL, relation bulk writes and database administration can bypass callbacks. The host must keep those out of product mutation paths and restrict database access. Request bytes and identities contain sensitive business data; configure storage encryption, access and backups in the host and do not log them. Retention is permanent for now.

## Isolated integration verification

The test requires an existing host bundle supplying the dependencies above, a local PostgreSQL server on `/tmp:5432`, and an OS-matching local role allowed to create task databases. It creates two uniquely named task databases, exercises actual engine models and migrations in both storage modes, and drops only those databases on completion or error. It does not boot the host app or load its database settings.

```sh
# From a compatible host bundle; use the path to this checkout:
bundle exec ruby /path/to/einvoice-lhdn/integration/persistence_test.rb
```

Verified:16 tests/368 assertions across same-database/shared-pool, same-database/separate-pool and separate-database configurations. Cases include concurrent single-winner claims, context mismatch/unavailable acknowledgment, transaction refusal, immutable snapshots, uncertain-state no-resend, correlated receipts, retention, database constraints, cold loading, committed-before-HTTP dispatch, timeout, result-storage outage, corrupt request hash, environment mismatch and duplicate delivery. Host migration installation, authorization/readiness, live LHDN behavior and the full workflow remain separate verification obligations.
