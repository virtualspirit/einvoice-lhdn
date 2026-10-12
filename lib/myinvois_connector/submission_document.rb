# frozen_string_literal: true

require "base64"
require "digest"

module MyInvoisConnector
  # Receives final signed/validated bytes; it does not create or validate UBL.
  class SubmissionDocument
    MAX_BYTES = 300_000
    FORMATS = %w[XML JSON].freeze

    attr_reader :bytes, :format, :code_number, :document_hash

    def initialize(bytes:, format:, code_number:)
      unless bytes.is_a?(String) && !bytes.empty? && bytes.bytesize <= MAX_BYTES
        raise ArgumentError, "document must contain between 1 and 300000 bytes"
      end
      unless FORMATS.include?(format)
        raise ArgumentError, "document format must be XML or JSON"
      end
      unless code_number.is_a?(String) && !code_number.strip.empty?
        raise ArgumentError, "code number must be a nonempty string"
      end

      number = code_number.encode(Encoding::UTF_8)
      raise ArgumentError, "code number must be valid UTF-8" unless number.valid_encoding?

      @bytes = bytes.dup.force_encoding(Encoding::BINARY).freeze
      @format = format.dup.freeze
      @code_number = number.freeze
      @document_hash = Digest::SHA256.hexdigest(@bytes).freeze
      @encoded_document = Base64.strict_encode64(@bytes).freeze
      freeze
    rescue EncodingError
      raise ArgumentError, "code number must be valid UTF-8"
    end

    def to_h
      {
        "format" => format,
        "document" => @encoded_document,
        "documentHash" => document_hash,
        "codeNumber" => code_number
      }.freeze
    end
  end
end
