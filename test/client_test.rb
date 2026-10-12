# frozen_string_literal: true

require "minitest/autorun"
require "webmock/minitest"
require "json"
require "open3"
require "rbconfig"
require_relative "../lib/einvoice-lhdn"

WebMock.disable_net_connect!

class ClientTest < Minitest::Test
  HOST = "https://preprod-api.myinvois.hasil.gov.my"
  SUBMIT_URL = "#{HOST}/api/v1.0/documentsubmissions/"
  CANCEL_URL = "#{HOST}/api/v1.0/documents/state/DEMO001/state"

  def setup
    @client = MyInvoisConnector::Client.new(
      client_id: "fictional-client", client_secret: "fictional-secret", represented_taxpayer: "DEMOONLY"
    )
    stub_request(:post, "#{HOST}/connect/token").to_return(status: 200, body: {
      access_token: "fictional-token", token_type: "Bearer", expires_in: 3600
    }.to_json)
    @submission = MyInvoisConnector::Submission.new(documents: %w[DEMO-A DEMO-B].map do |number|
      MyInvoisConnector::SubmissionDocument.new(bytes: "<Invoice>#{number}</Invoice>\n", format: "XML", code_number: number)
    end)
  end

  def receipt(**changes)
    {
      submissionUid: "BATCH001",
      acceptedDocuments: [{ uuid: "DEMO001", invoiceCodeNumber: "DEMO-A" }],
      rejectedDocuments: [{ invoiceCodeNumber: "DEMO-B", error: { code: "Invalid", message: "fictional-private-detail" } }]
    }.merge(changes)
  end

  def submission_response(data = receipt)
    stub_request(:post, SUBMIT_URL).to_return(status: 202, body: data.to_json)
  end

  def test_exact_envelope_is_sent_once_and_partial_acceptance_is_not_validity
    request = submission_response.with(body: @submission.body, headers: {
      "Content-Type" => "application/json", "Authorization" => "Bearer fictional-token"
    })
    result = @client.submit(submission: @submission)
    assert_equal "BATCH001", result.submission_uid
    assert_equal "DEMO001", result.accepted_documents.first["uuid"]
    assert_equal "Invalid", result.rejected_documents.first["error"]["code"]
    refute result.respond_to?(:valid?)
    assert_raises(FrozenError) { result.rejected_documents.first["error"]["message"] << "edit" }
    refute_includes result.inspect, "fictional-private-detail"
    assert_requested request, times: 1
  end

  def test_receipt_supports_documented_uid_spelling_and_rejects_conflict
    submission_response(receipt(submissionUid: nil, submissionUID: "BATCH001"))
    assert_equal "BATCH001", @client.submit(submission: @submission).submission_uid
    submission_response(receipt(submissionUID: "OTHER"))
    assert_raises(MyInvoisConnector::UncertainResultError) { @client.submit(submission: @submission) }
  end

  def test_all_rejected_without_batch_is_a_complete_receipt
    submission_response(receipt(submissionUid: nil, acceptedDocuments: [], rejectedDocuments: %w[DEMO-A DEMO-B].map do |code|
      { invoiceCodeNumber: code, error: { code: "Invalid" } }
    end))
    result = @client.submit(submission: @submission)
    assert_nil result.submission_uid
    assert_empty result.accepted_documents
    assert_equal 2, result.rejected_documents.size
  end

  def test_incomplete_unknown_duplicate_or_invalid_receipts_are_uncertain
    [receipt(rejectedDocuments: []),
     receipt(rejectedDocuments: [{ invoiceCodeNumber: "OTHER", error: {} }]),
     receipt(rejectedDocuments: [{ invoiceCodeNumber: "DEMO-A", error: {} }]),
     receipt(acceptedDocuments: [{ uuid: "../bad", invoiceCodeNumber: "DEMO-A" }]),
     receipt(submissionUid: nil), receipt(acceptedDocuments: [nil]),
     receipt(rejectedDocuments: [{ invoiceCodeNumber: "DEMO-B" }])].each do |body|
      submission_response(body)
      error = assert_raises(MyInvoisConnector::UncertainResultError) { @client.submit(submission: @submission) }
      assert_equal 202, error.status
      assert_nil error.cause
    end
  end

  def test_transport_failure_or_server_failure_is_uncertain_without_retry
    request = stub_request(:post, SUBMIT_URL).to_timeout
    error = assert_raises(MyInvoisConnector::UncertainResultError) { @client.submit(submission: @submission) }
    assert_nil error.cause
    assert_requested request, times: 1
    request.to_return(status: 503, headers: { "Retry-After" => "15" }, body: "fictional-secret")
    error = assert_raises(MyInvoisConnector::UncertainResultError) { @client.submit(submission: @submission) }
    assert_equal 15, error.retry_after
    refute_includes error.full_message, "fictional-secret"
    assert_requested request, times: 2
  end

  def test_malformed_or_unexpected_success_is_uncertain
    request = stub_request(:post, SUBMIT_URL).to_return(status: 202, body: "private{")
    error = assert_raises(MyInvoisConnector::UncertainResultError) { @client.submit(submission: @submission) }
    refute_includes error.full_message, "private{"
    request.to_return(status: 200, body: receipt.to_json)
    assert_raises(MyInvoisConnector::UncertainResultError) { @client.submit(submission: @submission) }
  end

  def test_duplicate_requires_reconciliation_and_retains_retry_hint
    request = stub_request(:post, SUBMIT_URL).to_return(status: 422, headers: { "Retry-After" => "600" })
    error = assert_raises(MyInvoisConnector::DuplicateSubmissionError) { @client.submit(submission: @submission) }
    assert_kind_of MyInvoisConnector::UncertainResultError, error
    assert_equal 600, error.retry_after
    assert_requested request, times: 1
  end

  def test_deterministic_failure_and_throttle_are_distinct
    request = stub_request(:post, SUBMIT_URL).to_return(status: 400)
    assert_raises(MyInvoisConnector::InvalidRequestError) { @client.submit(submission: @submission) }
    request.to_return(status: 403)
    assert_raises(MyInvoisConnector::AuthorizationError) { @client.submit(submission: @submission) }
    request.to_return(status: 429, headers: { "Retry-After" => "60" })
    error = assert_raises(MyInvoisConnector::RateLimitError) { @client.submit(submission: @submission) }
    assert_equal 60, error.retry_after
  end

  def test_authentication_failure_is_before_attempt_and_not_uncertain
    request = stub_request(:post, "#{HOST}/connect/token").to_return(status: 200, body: "bad{")
    assert_raises(MyInvoisConnector::ProtocolError) { @client.submit(submission: @submission) }
    request.to_timeout
    assert_raises(MyInvoisConnector::NetworkError) { @client.cancel(uuid: "DEMO001", reason: "Fictional reason") }
    assert_not_requested :post, SUBMIT_URL
    assert_not_requested :put, CANCEL_URL
  end

  def test_cancellation_sends_reason_and_requires_matching_confirmed_status
    request = stub_request(:put, CANCEL_URL).with(body: { status: "cancelled", reason: "Fictional correction" }.to_json)
      .to_return(status: 200, body: { uuid: "DEMO001", status: "Cancelled" }.to_json)
    result = @client.cancel(uuid: "DEMO001", reason: "Fictional correction")
    assert_equal "Cancelled", result["status"]
    assert result.frozen?
    assert_requested request, times: 1
    [{ uuid: "OTHER", status: "Cancelled" }, { uuid: "DEMO001", status: "Valid" },
     { uuid: "DEMO001", status: "Cancelled", error: {} }].each do |body|
      request.to_return(status: 200, body: body.to_json)
      assert_raises(MyInvoisConnector::UncertainResultError) { @client.cancel(uuid: "DEMO001", reason: "Fictional correction") }
    end
  end

  def test_cancellation_failures_never_imply_unlock_or_resend
    request = stub_request(:put, CANCEL_URL).to_return(status: 400)
    assert_raises(MyInvoisConnector::InvalidRequestError) { @client.cancel(uuid: "DEMO001", reason: "Fictional correction") }
    request.to_timeout
    assert_raises(MyInvoisConnector::UncertainResultError) { @client.cancel(uuid: "DEMO001", reason: "Fictional correction") }
    assert_requested request, times: 2
  end

  def test_invalid_inputs_fail_before_login
    assert_raises(ArgumentError) { @client.submit(submission: { documents: [] }) }
    ["", "   ", "字" * 301].each do |reason|
      assert_raises(ArgumentError) { @client.cancel(uuid: "DEMO001", reason: reason) }
    end
    assert_raises(ArgumentError) { @client.cancel(uuid: "../bad", reason: "Fictional") }
    assert_not_requested :post, "#{HOST}/connect/token"
  end

  def test_concrete_client_cold_loads_without_rails
    root = File.expand_path("../lib", __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", root, "-e",
      'require "myinvois_connector/client"; abort if defined?(Rails); abort unless MyInvoisConnector::Client < MyInvoisConnector::ReadClient; puts "ok"')
    assert status.success?, stderr
    assert_equal "ok\n", stdout
  end
end
