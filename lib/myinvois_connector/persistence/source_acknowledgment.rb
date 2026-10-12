# frozen_string_literal: true

require_relative "../persistence"

module MyInvoisConnector
  module Persistence
    # Trusted host observation, never an authorization token from a web form.
    class SourceAcknowledgment
      FIELDS = %i[intent_uuid tenant_key environment source_reference source_digest request_hash token].freeze
      attr_reader(*FIELDS)

      def initialize(**attributes)
        raise ArgumentError, "acknowledgment fields are incomplete" unless attributes.keys.sort == FIELDS.sort
        FIELDS.each do |field|
          value = attributes.fetch(field)
          unless value.is_a?(String) && value.valid_encoding? && !value.strip.empty?
            raise ArgumentError, "acknowledgment fields must be nonempty strings"
          end
          instance_variable_set("@#{field}", value.dup.freeze)
        end
        freeze
      end

      def matches?(intent)
        (FIELDS - [:token]).all? { |field| public_send(field) == intent.public_send(field) }
      end

      def inspect
        "#<MyInvoisConnector::Persistence::SourceAcknowledgment context=[FILTERED]>"
      end
    end
  end
end
