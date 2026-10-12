# frozen_string_literal: true

require_relative "errors"

module MyInvoisConnector
  # Initial receipt only: accepted documents are still awaiting validation.
  class SubmissionReceipt
    attr_reader :submission_uid, :accepted_documents, :rejected_documents

    def initialize(data:, code_numbers:)
      invalid! unless data.is_a?(Hash)
      ids = [data["submissionUid"], data["submissionUID"]].compact
      invalid! if ids.uniq.size > 1
      uid = ids.first
      accepted = data["acceptedDocuments"]
      rejected = data["rejectedDocuments"]
      invalid! unless accepted.is_a?(Array) && rejected.is_a?(Array)
      invalid! unless accepted.all? { |item| item.is_a?(Hash) && identifier?(item["uuid"]) }
      invalid! unless rejected.all? { |item| item.is_a?(Hash) && item["error"].is_a?(Hash) }
      # Some all-rejected responses have no batch ID; they must never be polled.
      invalid! unless uid.nil? ? accepted.empty? : identifier?(uid)
      numbers = (accepted + rejected).map { |item| item["invoiceCodeNumber"] }
      invalid! unless numbers.all? { |number| number.is_a?(String) } &&
                      numbers.uniq.size == numbers.size && numbers.sort == code_numbers.sort
      invalid! unless accepted.map { |item| item["uuid"] }.uniq.size == accepted.size

      @submission_uid = uid&.dup&.freeze
      @accepted_documents = snapshot(accepted)
      @rejected_documents = snapshot(rejected)
      freeze
    end

    def inspect
      "#<MyInvoisConnector::SubmissionReceipt accepted=#{accepted_documents.size} rejected=#{rejected_documents.size}>"
    end

    private

    def identifier?(value)
      value.is_a?(String) && value.ascii_only? && value.match?(/\A[A-Za-z0-9]+\z/)
    end

    def invalid!
      raise ProtocolError.new("submission_receipt_uncorrelated"), cause: nil
    end

    def snapshot(value)
      case value
      when Hash then value.to_h { |key, item| [snapshot(key), snapshot(item)] }.freeze
      when Array then value.map { |item| snapshot(item) }.freeze
      when String then value.dup.freeze
      else value
      end
    end
  end
end
