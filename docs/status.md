# Implementation status

Updated2026-10-12. Private work in progress, independently authored from official protocol documentation. No license or public redistribution permission is assigned. Do not publish this package to RubyGems.

Implemented: immutable final-byte envelopes, SHA256/base64, bounded homogeneous batches, all-eight-type code vocabulary, represented-taxpayer authentication, isolated per-instance token reuse, TIN/identity verification, explicit paginated status reads, immutable document details, Valid-only validation URLs, explicit submission/cancellation requests, correlated immutable initial receipts and typed uncertain/duplicate results. ReadClient remains read-only; Client exposes writes explicitly.

Verification:40 tests,202 assertions pass locally on Ruby3.0.3 with Faraday2.7.11 and stubbed HTTP. External network access is disabled in tests. CI defines Ruby3.0 and3.3 checks; the initial GitHub run did not start because of the organization's billing/spending limit. Local success does not establish hosted CI or live provider success.

Pending: all-eight-type UBL generation and signing/version validation, optional Rails persistence engine in both database modes, durable dispatch/reconciliation, source financial locking, tenant permissions/readiness, consolidation, QR/download output and host UI. No live sandbox or production operation has been verified. Type vocabulary is not schema implementation or compliance certification.

Host responsibilities: resolve authorized tenant identity, securely provision intermediary credentials/certificates, enforce readiness and permissions, own financial effects, reserve source records and acknowledge intent before dispatch. Separate-store recovery must not silently unlock an ambiguous submission or blindly resend it. These host workflow obligations are not solved by this connector.

Official contracts: [intermediary login](https://sdk.myinvois.hasil.gov.my/api/08-login-as-intermediary-system/), [submission](https://sdk.myinvois.hasil.gov.my/einvoicingapi/02-submit-documents/), [get submission](https://sdk.myinvois.hasil.gov.my/einvoicingapi/06-get-submission/), [document details](https://sdk.myinvois.hasil.gov.my/einvoicingapi/08-get-document-details/), [verify TIN](https://sdk.myinvois.hasil.gov.my/einvoicingapi/01-validate-taxpayer-tin/), [environment FAQ](https://sdk.myinvois.hasil.gov.my/faq/). Reviewed2026-10-12; recheck current documentation before implementing affected behavior.
