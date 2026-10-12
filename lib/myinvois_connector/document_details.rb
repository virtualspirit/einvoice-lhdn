# frozen_string_literal: true

require_relative "errors"
require_relative "environments"

module MyInvoisConnector
  class DocumentDetails
    attr_reader :environment, :data

    def initialize(data:, environment:, expected_uuid:)
      Environments.fetch(environment)
      unless data.is_a?(Hash) && data["uuid"] == expected_uuid
        raise ProtocolError.new("document_identity_mismatch"), cause: nil
      end
      @environment = environment
      @data = snapshot(data)
      freeze
    end

    def [](key)
      data[key]
    end

    private

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
