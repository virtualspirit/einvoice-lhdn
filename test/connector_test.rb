# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "base64"
require "digest"
require "open3"
require "rbconfig"
require_relative "../lib/myinvois_connector"

class ConnectorTest < Minitest::Test
  def document(bytes: "<Invoice>fictional</Invoice>", format: "XML", number: "DEMO-001")
    MyInvoisConnector::SubmissionDocument.new(bytes: bytes, format: format, code_number: number)
  end

  def test_exact_signed_bytes_survive_hashing_and_encoding
    original = "<Invoice>\r\n  <Name>測試 café</Name>\n</Invoice>".b
    value = document(bytes: original)
    wire = JSON.parse(MyInvoisConnector::Submission.new(documents: [value]).body).fetch("documents").first
    assert_equal original, Base64.strict_decode64(wire.fetch("document"))
    assert_equal Digest::SHA256.hexdigest(original), wire.fetch("documentHash")
    assert_equal "XML", wire.fetch("format")
    assert_equal "DEMO-001", wire.fetch("codeNumber")
    refute_match(/\s/, wire.fetch("document"))
  end

  def test_caller_cannot_change_the_document_or_batch_after_creation
    bytes = +"<Invoice/>"
    number = +"DEMO-001"
    format = +"XML"
    value = document(bytes: bytes, number: number, format: format)
    values = [value]
    submission = MyInvoisConnector::Submission.new(documents: values)
    before = submission.body.dup
    bytes.replace("changed")
    number.replace("changed")
    format.replace("JSON")
    values.clear
    assert_equal before, submission.body
    assert_equal "<Invoice/>".b, value.bytes
    assert_equal "DEMO-001", value.code_number
    assert_raises(FrozenError) { value.bytes << "x" }
    assert_raises(FrozenError) { value.to_h["document"] << "x" }
    assert_raises(FrozenError) { value.to_h["format"] = "JSON" }
    assert_raises(FrozenError) { submission.documents.clear }
    assert_raises(FrozenError) { submission.body << "x" }
  end

  def test_document_limits_count_bytes_instead_of_characters
    assert_equal 300_000, document(bytes: "a" * 300_000).bytes.bytesize
    assert_raises(ArgumentError) { document(bytes: "a" * 300_001) }
    assert_raises(ArgumentError) { document(bytes: "測" * 100_001) }
    assert_raises(ArgumentError) { document(bytes: "") }
    assert_raises(ArgumentError) { document(bytes: nil) }
  end

  def test_rejects_invalid_document_metadata_without_echoing_input
    ["xml", "YAML", nil].each { |format| assert_raises(ArgumentError) { document(format: format) } }
    [nil, "", "  ", "\xff".b].each do |number|
      error = assert_raises(ArgumentError) { document(number: number) }
      refute_includes error.message, "\xff".b
    end
  end

  def test_json_documents_preserve_whitespace_and_multibyte_code_numbers
    bytes = "{\n  \"name\": \"café\"\n}"
    value = document(bytes: bytes, format: "JSON", number: "測試-001")
    wire = JSON.parse(MyInvoisConnector::Submission.new(documents: [value]).body)["documents"].first
    assert_equal bytes.b, Base64.strict_decode64(wire["document"])
    assert_equal "測試-001", wire["codeNumber"]
  end

  def test_batch_count_boundaries_and_entry_type
    values = 100.times.map { |index| document(number: "DEMO-#{index}") }
    assert_equal 100, MyInvoisConnector::Submission.new(documents: values).documents.size
    [[], values + [document(number: "EXTRA")], nil, [Object.new]].each do |input|
      assert_raises(ArgumentError) { MyInvoisConnector::Submission.new(documents: input) }
    end
  end

  def test_rejects_mixed_formats_and_ambiguous_response_correlation
    assert_raises(ArgumentError) do
      MyInvoisConnector::Submission.new(documents: [document, document(format: "JSON", number: "DEMO-002")])
    end
    assert_raises(ArgumentError) do
      MyInvoisConnector::Submission.new(documents: [document, document])
    end
  end

  def test_batch_budget_includes_base64_and_json_overhead
    values = 12.times.map { |index| document(bytes: "a" * 300_000, number: "DEMO-#{index}") }
    submission = MyInvoisConnector::Submission.new(documents: values)
    assert_operator submission.body.bytesize, :>, 3_600_000
    assert_operator submission.body.bytesize, :<=, 5_000_000
    assert_raises(ArgumentError) do
      MyInvoisConnector::Submission.new(documents: values + [document(bytes: "a" * 300_000, number: "EXTRA")])
    end
  end

  def test_type_vocabulary_contains_the_eight_official_codes
    assert_equal %w[01 02 03 04 11 12 13 14], MyInvoisConnector::DocumentTypes::CODES.values
    assert_equal "14", MyInvoisConnector::DocumentTypes.code(:self_billed_refund_note)
    assert_raises(ArgumentError) { MyInvoisConnector::DocumentTypes.code(:unknown) }
    assert_raises(FrozenError) { MyInvoisConnector::DocumentTypes::CODES[:invoice] << "9" }
  end

  def test_public_constants_load_independently_without_rails
    root = File.expand_path("../lib", __dir__)
    %w[version document_types submission_document submission].each do |name|
      program = "require 'myinvois_connector/#{name}'; abort('unexpected Rails load') if defined?(Rails)"
      output, status = Open3.capture2e(RbConfig.ruby, "-I", root, "-e", program)
      assert status.success?, "cold require #{name}: #{output}"
    end
  end
end
