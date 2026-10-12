# frozen_string_literal: true

require_relative "read_client"
require_relative "submission"
require_relative "submission_receipt"

module MyInvoisConnector
  # Explicit protocol writes. The caller must enforce readiness, permissions,
  # source reservation and durable attempts before calling these methods.
  class Client < ReadClient
    def submit(submission:)
      unless submission.instance_of?(Submission)
        raise ArgumentError, "immutable submission is required"
      end
      response = write_response(:post, "/api/v1.0/documentsubmissions/", submission.body, expected_status: 202)
      decode_write_response(response, "submission_response_uncertain") do |data|
        SubmissionReceipt.new(data: data, code_numbers: submission.documents.map(&:code_number))
      end
    end

    def cancel(uuid:, reason:)
      uid = identifier(uuid)
      explanation = nonempty_string(reason)
      raise ArgumentError, "cancellation reason exceeds 300 characters" if explanation.length > 300
      body = JSON.generate(status: "cancelled", reason: explanation)
      response = write_response(:put, "/api/v1.0/documents/state/#{uid}/state", body, expected_status: 200)
      decode_write_response(response, "cancellation_response_uncertain") do |data|
        unless data["uuid"] == uid && data["status"] == "Cancelled" && data["error"].nil?
          raise ProtocolError.new("cancellation_response_uncorrelated"), cause: nil
        end
        data
      end
    end

    private

    def decode_write_response(response, failure_code)
      yield parse_json(response.body)
    rescue ProtocolError
      raise UncertainResultError.new(failure_code, status: response.status), cause: nil
    end

    def write_response(method, path, body, expected_status:)
      # Authentication is before the attempt. Its failure must not imply a
      # document request was sent. No transport retry middleware is installed.
      token = access_token
      begin
        response = @api.public_send(method, path) do |request|
          request.headers["Accept"] = "application/json"
          request.headers["Content-Type"] = "application/json"
          request.headers["Authorization"] = "Bearer #{token}"
          request.body = body
        end
      rescue Faraday::Error
        raise UncertainResultError.new("write_transport_uncertain"), cause: nil
      end

      status = response.status
      return response if status == expected_status
      hint = retry_after(response.headers["retry-after"])
      if method == :post && status == 422
        raise DuplicateSubmissionError.new("duplicate_submission_requires_reconciliation", status: status, retry_after: hint), cause: nil
      end
      if status >= 500 || status == 408 || status.between?(200, 399)
        raise UncertainResultError.new("write_http_uncertain", status: status, retry_after: hint), cause: nil
      end
      check_status(response)
    end
  end
end
