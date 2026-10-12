# frozen_string_literal: true

require "json"
require_relative "submission_document"

module MyInvoisConnector
  # Offline envelope only: deliberately has no HTTP client or dispatch method.
  class Submission
    MAX_DOCUMENTS = 100
    MAX_BYTES = 5_000_000

    attr_reader :documents, :body

    def initialize(documents:)
      unless documents.is_a?(Array) && documents.size.between?(1, MAX_DOCUMENTS)
        raise ArgumentError, "submission must contain between 1 and 100 documents"
      end
      unless documents.all? { |document| document.instance_of?(SubmissionDocument) }
        raise ArgumentError, "submission requires immutable submission documents"
      end

      @documents = documents.dup.freeze
      unless @documents.map(&:format).uniq.size == 1
        raise ArgumentError, "submission documents must use the same format"
      end
      unless @documents.map(&:code_number).uniq.size == @documents.size
        raise ArgumentError, "submission code numbers must be unique for correlation"
      end

      # Stop before materializing an oversized batch (base64 can expand it).
      body = +'{"documents":['
      @documents.each_with_index do |document, index|
        encoded = JSON.generate(document.to_h)
        separator = index.zero? ? "" : ","
        if body.bytesize + separator.bytesize + encoded.bytesize + 2 > MAX_BYTES
          raise ArgumentError, "serialized submission exceeds 5000000 bytes"
        end
        body << separator << encoded
      end
      @body = (body << "]}").freeze

      freeze
    end
  end
end
