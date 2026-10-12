# einvoice-lhdn

An independently packaged Ruby connector foundation. Requires Ruby 3.0.3 or later and Faraday 2.7–2.x. It is not yet integrated into event_backend.

Install from the private repository using your organization's existing GitHub authentication:

```ruby
gem "einvoice-lhdn", git: "https://github.com/virtualspirit/einvoice-lhdn.git"
```

Pin a reviewed commit in consuming applications. Never embed a GitHub token in the URL. `require "einvoice-lhdn"` and `require "myinvois_connector"` load the same `MyInvoisConnector` namespace.

```ruby
require "myinvois_connector"

# bytes must already be the final document produced by schema/signing code.
document = MyInvoisConnector::SubmissionDocument.new(
  bytes: final_document_bytes,
  format: "XML",
  code_number: "INV-DEMO-001"
)
submission = MyInvoisConnector::Submission.new(documents: [document])
submission.body # JSON envelope; no request is sent
```

`SubmissionDocument` preserves final bytes without parsing, minifying or signing. Its SHA256 hash and strict base64 encoding use the same immutable copy. `Submission` returns a frozen serialized body; it rejects mixed document formats, ambiguous duplicate code numbers and oversized envelopes. Conservative limits are 300,000 raw bytes per document, 5,000,000 serialized request bytes including base64/JSON overhead, and 100 documents per request. Duplicate-number rejection is a local batch-correlation safeguard; distinct batches may reuse a number where the future business/schema contract permits it.

Each public file can be required independently, for example `require "myinvois_connector/submission"`. `DocumentTypes.code(:self_billed_refund_note)` returns `"14"`; the code table covers all eight types but does not implement their UBL schemas.

`ReadClient` provides intermediary authentication, TIN/identity verification, paginated submission status, document details and a Valid-only validation-link helper. Construct one client per authorized represented-taxpayer/environment/credential context. Supply credentials through your application's secure provisioning mechanism; do not put credentials or taxpayer data in examples, logs or exception reports. Sandbox is the default; supported environments are `:sandbox` and `:production` with fixed official HTTPS hosts. Production capability does not establish tenant readiness.

Tokens are reused only within that client instance, protected by a mutex and provider-supplied expiry. There is no cross-process token cache. HTTP requests have bounded timeouts, no automatic retries or redirects, and no request logger. Typed errors expose a safe code, HTTP status and optional Retry-After seconds; they omit provider bodies and nested transport exceptions. Only an API404 during TIN verification returns false; unavailable, malformed and unauthorized requests raise distinct errors. Submission reads expose each document's status and explicit pagination. The caller owns page iteration and scheduling.

`Client` extends `ReadClient` with explicit `submit(submission:)` and `cancel(uuid:, reason:)` methods. Submit returns an immutable `SubmissionReceipt` with correlated accepted/rejected documents; accepted means awaiting validation. Cancellation returns only a matching confirmed Cancelled response. The caller must enforce readiness, permissions, source reservation and durable attempt recording before invoking a write.

`UncertainResultError` means a write may have reached the provider: retain the source lock and reconcile rather than resend. `DuplicateSubmissionError` is an uncertain-result subtype with any provider retry hint; a hint does not authorize automatic resubmission. Preflight authentication failures are distinct from write-attempt failures. No automatic POST/PUT retry is performed. Cancel reasons must contain1–300 characters; the engine/host must enforce validation-time windows, reference chains and represented-taxpayer authority.

This slice provides no UBL generation, schema/signature verification, recipient rejection API, database persistence, background jobs or source locking. Envelope construction is not evidence that a document is eligible, signed, accepted or Valid. Host dispatch must pass the engine/host readiness, permission and source-lock gates. Do not log document bytes, request bodies or returned taxpayer/document data. Responses are bounded after transport; streaming download limits remain future work.

Run offline tests from this repository:

```sh
bundle install
bundle exec rake test
```

Protocol sources: [Submit Documents](https://sdk.myinvois.hasil.gov.my/einvoicingapi/02-submit-documents/), [type codes](https://sdk.myinvois.hasil.gov.my/codes/e-invoice-types/). See [implementation status](docs/status.md) for coverage and limitations. Checked 2026-10-12. This private package is not licensed or approved for public publication.
