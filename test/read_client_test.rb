# frozen_string_literal: true

require "minitest/autorun"
require "webmock/minitest"
require "json"
require "uri"
require "bigdecimal"
require "open3"
require "rbconfig"
require_relative "../lib/myinvois_connector"

WebMock.disable_net_connect!

class ReadClientTest < Minitest::Test
  SANDBOX = "https://preprod-api.myinvois.hasil.gov.my"
  PRODUCTION = "https://api.myinvois.hasil.gov.my"

  def setup
    @now = 100.0
    @client = client
    login_stub
  end

  def client(taxpayer: "DEMOONLY", environment: :sandbox, **options)
    MyInvoisConnector::ReadClient.new(
      client_id: "fictional-client", client_secret: "fictional-secret",
      represented_taxpayer: taxpayer, environment: environment,
      clock: -> { @now }, **options
    )
  end

  def login_stub(host: SANDBOX, taxpayer: "DEMOONLY", token: "fictional-token", lifetime: 3600)
    stub_request(:post, "#{host}/connect/token")
      .with(headers: { "Onbehalfof" => taxpayer }, body: {
        "client_id" => "fictional-client", "client_secret" => "fictional-secret",
        "grant_type" => "client_credentials", "scope" => "InvoicingAPI"
      }).to_return(status: 200, body: { access_token: token, token_type: "Bearer", expires_in: lifetime }.to_json)
  end

  def details_stub(host: SANDBOX, uuid: "DEMO001", token: "fictional-token", status: "Valid", **fields)
    stub_request(:get, "#{host}/api/v1.0/documents/#{uuid}/details")
      .with(headers: { "Authorization" => "Bearer #{token}" })
      .to_return(status: 200, body: { uuid: uuid, status: status, longId: "DEMO-LONG", **fields }.to_json)
  end

  def test_intermediary_login_is_cached_using_provider_lifetime
    details_stub
    @client.document_details(uuid: "DEMO001")
    @now += 3500
    @client.document_details(uuid: "DEMO001")
    assert_requested :post, "#{SANDBOX}/connect/token", times: 1
    @now += 41
    @client.document_details(uuid: "DEMO001")
    assert_requested :post, "#{SANDBOX}/connect/token", times: 2
  end

  def test_concurrent_reads_share_only_one_login_per_client
    details_stub
    threads = 6.times.map { Thread.new { @client.document_details(uuid: "DEMO001") } }
    threads.each(&:value)
    assert_requested :post, "#{SANDBOX}/connect/token", times: 1
    assert_requested :get, "#{SANDBOX}/api/v1.0/documents/DEMO001/details", times: 6
  end

  def test_taxpayer_and_environment_tokens_never_cross
    login_stub(taxpayer: "DEMOTWO:ROBDEMO", token: "token-two")
    login_stub(host: PRODUCTION, token: "production-token")
    details_stub
    details_stub(uuid: "DEMO002", token: "token-two")
    details_stub(host: PRODUCTION, token: "production-token")
    @client.document_details(uuid: "DEMO001")
    client(taxpayer: "DEMOTWO:ROBDEMO").document_details(uuid: "DEMO002")
    client(environment: :production).document_details(uuid: "DEMO001")
    assert_requested :post, "#{SANDBOX}/connect/token", times: 2
    assert_requested :post, "#{PRODUCTION}/connect/token", times: 1
  end

  def test_expired_token_is_discarded_without_automatic_retry
    request = stub_request(:get, "#{SANDBOX}/api/v1.0/documents/DEMO001/details")
      .to_return(status: 401, body: "fictional-sensitive-body")
    error = assert_raises(MyInvoisConnector::AuthenticationError) { @client.document_details(uuid: "DEMO001") }
    assert_equal 401, error.status
    assert_nil error.cause
    assert_requested request, times: 1
    assert_requested :post, "#{SANDBOX}/connect/token", times: 1
    details_stub
    @client.document_details(uuid: "DEMO001")
    assert_requested :post, "#{SANDBOX}/connect/token", times: 2
  end

  def test_tin_verification_distinguishes_valid_invalid_and_bad_request
    url = "#{SANDBOX}/api/v1.0/taxpayer/validate/DEMOONLY"
    params = { "idType" => "BRN", "idValue" => "FICTIONAL/ ID" }
    stub = stub_request(:get, url).with(query: params).to_return(status: 200, body: "")
    assert @client.verify_tin(tin: "DEMOONLY", id_type: "BRN", id_value: "FICTIONAL/ ID")
    stub.to_return(status: 404)
    refute @client.verify_tin(tin: "DEMOONLY", id_type: "BRN", id_value: "FICTIONAL/ ID")
    stub.to_return(status: 400)
    assert_raises(MyInvoisConnector::InvalidRequestError) do
      @client.verify_tin(tin: "DEMOONLY", id_type: "BRN", id_value: "FICTIONAL/ ID")
    end
  end

  def test_authentication_404_is_not_misreported_as_invalid_tin
    stub_request(:post, "#{SANDBOX}/connect/token").to_return(status: 404)
    assert_raises(MyInvoisConnector::AuthenticationError) do
      @client.verify_tin(tin: "DEMOONLY", id_type: "BRN", id_value: "FICTIONAL")
    end
    assert_not_requested :get, /taxpayer\/validate/
  end

  def test_throttle_preserves_retry_hint_without_resending
    stub = stub_request(:get, "#{SANDBOX}/api/v1.0/documents/DEMO001/details")
      .to_return(status: 429, headers: { "Retry-After" => "17" }, body: "fictional-secret")
    error = assert_raises(MyInvoisConnector::RateLimitError) { @client.document_details(uuid: "DEMO001") }
    assert_equal 17, error.retry_after
    assert_equal 429, error.status
    refute_includes error.full_message, "fictional-secret"
    assert_requested stub, times: 1
  end

  def test_http_date_retry_hint_and_invalid_hint
    url = "#{SANDBOX}/api/v1.0/documents/DEMO001/details"
    stub = stub_request(:get, url).to_return(status: 503, headers: { "Retry-After" => (Time.now + 120).httpdate })
    error = assert_raises(MyInvoisConnector::ProviderError) { @client.document_details(uuid: "DEMO001") }
    assert_includes 118..121, error.retry_after
    stub.to_return(status: 503, headers: { "Retry-After" => "not-a-date" })
    error = assert_raises(MyInvoisConnector::ProviderError) { @client.document_details(uuid: "DEMO001") }
    assert_nil error.retry_after
  end

  def test_malformed_token_or_json_never_leaks_body_or_cause
    stub = stub_request(:post, "#{SANDBOX}/connect/token").to_return(status: 200, body: "fictional-secret{")
    error = assert_raises(MyInvoisConnector::ProtocolError) { @client.document_details(uuid: "DEMO001") }
    assert_nil error.cause
    refute_includes error.full_message, "fictional-secret"
    stub.to_return(status: 200, body: { access_token: "token\r\ninjection", token_type: "Bearer", expires_in: 3600 }.to_json)
    assert_raises(MyInvoisConnector::ProtocolError) { @client.document_details(uuid: "DEMO001") }
    assert_not_requested :get, /documents/
  end

  def test_short_lifetime_and_slow_authentication_are_safe
    login_stub(lifetime: 10)
    details_stub
    @client.document_details(uuid: "DEMO001")
    @now += 9.1
    @client.document_details(uuid: "DEMO001")
    assert_requested :post, "#{SANDBOX}/connect/token", times: 2
    @client = client
    stub_request(:post, "#{SANDBOX}/connect/token").to_return do
      @now += 20
      { status: 200, body: { access_token: "token", token_type: "Bearer", expires_in: 10 }.to_json }
    end
    assert_raises(MyInvoisConnector::AuthenticationError) { @client.document_details(uuid: "DEMO001") }
  end

  def test_document_identity_must_match_and_response_is_immutable
    details_stub(uuid: "DEMO001", validationResults: { validationSteps: [{ status: "Valid" }] })
    details = @client.document_details(uuid: "DEMO001")
    assert_equal "DEMO001", details["uuid"]
    assert_raises(FrozenError) { details.data["validationResults"]["validationSteps"].clear }
    stub_request(:get, "#{SANDBOX}/api/v1.0/documents/DEMO001/details")
      .to_return(status: 200, body: { uuid: "OTHER" }.to_json)
    assert_raises(MyInvoisConnector::ProtocolError) { @client.document_details(uuid: "DEMO001") }
  end

  def test_validation_url_requires_valid_matching_environment_and_plain_url
    details_stub(longId: "LONG AB/+?")
    details = @client.document_details(uuid: "DEMO001")
    assert_equal "https://preprod.myinvois.hasil.gov.my/DEMO001/share/LONG%20AB%2F%2B%3F", @client.validation_url(details)
    assert_nil client(environment: :production).validation_url(details)
    assert_nil @client.validation_url({ "status" => "Valid", "uuid" => "DEMO001", "longId" => "FAKE" })
    details_stub(status: "Submitted")
    assert_nil @client.validation_url(@client.document_details(uuid: "DEMO001"))
  end

  def test_paginated_status_preserves_mixed_document_outcomes_and_decimal_precision
    stub_request(:get, "#{SANDBOX}/api/v1.0/documentsubmissions/BATCH001")
      .with(query: { pageNo: "2", pageSize: "20" }).to_return(status: 200, body:
        '{"submissionUid":"BATCH001","overallStatus":"partially valid","documentSummary":[{"uuid":"DEMO002","status":"Invalid","totalPayableAmount":999999999999.99},{"uuid":"DEMO001","status":"Valid"}]}')
    result = @client.submission_status(submission_uid: "BATCH001", page: 2, page_size: 20)
    assert_equal %w[Invalid Valid], result["documentSummary"].map { |item| item["status"] }
    assert_equal BigDecimal("999999999999.99"), result["documentSummary"].first["totalPayableAmount"]
    assert_raises(FrozenError) { result["documentSummary"].first["status"] << "x" }
  end

  def test_invalid_inputs_fail_before_authentication
    ["../BATCH001", "BATCH/001", nil].each do |uid|
      assert_raises(ArgumentError) { @client.submission_status(submission_uid: uid) }
    end
    assert_raises(ArgumentError) { @client.submission_status(submission_uid: "BATCH001", page_size: 101) }
    assert_raises(ArgumentError) { @client.verify_tin(tin: "DEMOONLY", id_type: "OTHER", id_value: "DEMO") }
    assert_raises(ArgumentError) { client(taxpayer: "DEMO\r\nHeader") }
    assert_raises(ArgumentError) { client(environment: :unknown) }
    assert_not_requested :post, /connect\/token/
  end

  def test_network_errors_are_safe_and_not_negative_verification
    stub_request(:get, "#{SANDBOX}/api/v1.0/taxpayer/validate/DEMOONLY")
      .with(query: { idType: "BRN", idValue: "DEMO" }).to_timeout
    error = assert_raises(MyInvoisConnector::NetworkError) do
      @client.verify_tin(tin: "DEMOONLY", id_type: "BRN", id_value: "DEMO")
    end
    assert_nil error.cause
    refute_includes error.full_message, "idValue"
    refute_includes @client.inspect, "fictional-secret"
    refute_includes @client.inspect, "DEMOONLY"
  end

  def test_redirect_and_oversized_response_are_rejected
    url = "#{SANDBOX}/api/v1.0/documents/DEMO001/details"
    stub = stub_request(:get, url).to_return(status: 302, headers: { "Location" => "https://example.invalid" })
    assert_raises(MyInvoisConnector::ProviderError) { @client.document_details(uuid: "DEMO001") }
    assert_not_requested :get, "https://example.invalid"
    stub.to_return(status: 200, body: "x" * 2_000_001)
    assert_raises(MyInvoisConnector::ProtocolError) { @client.document_details(uuid: "DEMO001") }
  end

  def test_public_read_files_cold_load_without_rails_or_network
    root = File.expand_path("../lib", __dir__)
    %w[errors environments document_details read_client].each do |name|
      output, status = Open3.capture2e(RbConfig.ruby, "-I", root, "-e",
        "require 'myinvois_connector/#{name}'; abort 'Rails loaded' if defined?(Rails)")
      assert status.success?, "cold require #{name}: #{output}"
    end
    refute_respond_to @client, :submit
    refute_respond_to @client, :cancel
    refute_respond_to @client, :reject
  end
end
