# frozen_string_literal: true

require "securerandom"
require "digest"
require "json"
require_relative "../persistence"
require_relative "record"
require_relative "source_acknowledgment"

module MyInvoisConnector
  module Persistence
    class SubmissionIntent < Record
      self.table_name = "lhdn_submission_intents"

      IMMUTABLE = %w[intent_uuid tenant_key environment source_reference source_digest request_body request_hash code_numbers].freeze
      LIFECYCLE = %w[state acknowledgment attempted_at submission_uid receipt_data last_error_code].freeze
      attr_readonly(*IMMUTABLE)

      state_machine :state, initial: :awaiting_source do
        event(:acknowledge_source) { transition awaiting_source: :ready }
        event(:claim_attempt) { transition ready: :attempting }
        event(:accept_receipt) { transition attempting: :accepted }
        event(:reject_receipt) { transition attempting: :rejected }
        event(:record_uncertainty) { transition [:attempting, :uncertain] => :uncertain }
      end

      validates :intent_uuid, :tenant_key, :source_reference, :request_body, presence: true
      validates :environment, inclusion: { in: %w[sandbox production] }
      validates :source_digest, :request_hash, format: { with: /\A[a-f0-9]{64}\z/ }
      validates :intent_uuid, uniqueness: true
      validate :immutable_snapshot
      before_save :enforce_owned_write
      before_destroy { raise LifecycleError.new("intent_retention_prohibits_deletion"), cause: nil }

      def self.prepare!(tenant_key:, environment:, source_reference:, source_digest:, submission:)
        raise ArgumentError, "immutable submission is required" unless submission.instance_of?(MyInvoisConnector::Submission)
        record = new(tenant_key: tenant_key, environment: environment.to_s,
          source_reference: source_reference, source_digest: source_digest,
          intent_uuid: SecureRandom.uuid, request_body: submission.body,
          request_hash: Digest::SHA256.hexdigest(submission.body),
          code_numbers: submission.documents.map(&:code_number))
        record.send(:owned_write) { record.save! }
        record
      end

      def acknowledge!(source_owner:)
        with_lock do
          observed = verified_acknowledgment(source_owner)
          if ready?
            raise LifecycleError.new("source_acknowledgment_changed"), cause: nil unless acknowledgment == observed.token
            next
          end
          raise LifecycleError.new("intent_not_awaiting_source"), cause: nil unless awaiting_source?
          owned_write do
            self.acknowledgment = observed.token
            acknowledge_source!
          end
        end
        self
      end

      # Must be called outside an outer transaction: success means the claim is
      # committed before HTTP may begin. The source owner also checks its store.
      def claim!(source_owner:)
        if self.class.connection.transaction_open?
          raise LifecycleError.new("claim_requires_own_transaction"), cause: nil
        end
        claimed = false
        with_lock do
          if ready?
            observed = verified_acknowledgment(source_owner)
            raise LifecycleError.new("source_acknowledgment_changed"), cause: nil unless acknowledgment == observed.token
            owned_write do
              self.attempted_at = Time.now.utc
              claim_attempt!
            end
            claimed = true
          end
        end
        claimed
      end

      def record_receipt!(receipt:)
        unless receipt.instance_of?(MyInvoisConnector::SubmissionReceipt)
          raise ArgumentError, "correlated submission receipt is required"
        end
        numbers = (receipt.accepted_documents + receipt.rejected_documents).map { |item| item.fetch("invoiceCodeNumber") }
        with_lock do
          raise LifecycleError.new("intent_not_attempting"), cause: nil unless attempting?
          raise LifecycleError.new("receipt_numbers_mismatch"), cause: nil unless numbers.sort == code_numbers.sort
          owned_write do
            self.submission_uid = receipt.submission_uid
            self.receipt_data = { "acceptedDocuments" => receipt.accepted_documents, "rejectedDocuments" => receipt.rejected_documents }
            receipt.accepted_documents.empty? ? reject_receipt! : accept_receipt!
          end
        end
        self
      end

      def mark_uncertain!(code:)
        unless code.is_a?(String) && code.match?(/\A[a-z][a-z0-9_]{0,99}\z/)
          raise ArgumentError, "safe error code is required"
        end
        with_lock do
          raise LifecycleError.new("intent_not_attempting_or_uncertain"), cause: nil unless attempting? || uncertain?
          owned_write do
            self.last_error_code = code
            record_uncertainty!
          end
        end
        self
      end

      def request_bytes
        request_body.dup.freeze
      end

      def update_columns(*)
        raise LifecycleError.new("direct_intent_write_prohibited"), cause: nil
      end

      def delete
        raise LifecycleError.new("intent_retention_prohibits_deletion"), cause: nil
      end

      def inspect
        "#<MyInvoisConnector::Persistence::SubmissionIntent state=#{state} context=[FILTERED] payload=[FILTERED]>"
      end

      private

      def verified_acknowledgment(source_owner)
        # Implemented by a trusted host role. Must reject a reservation still
        # inside a host transaction or unavailable/unconfirmed source storage.
        observed = source_owner.acknowledgment_for(self)
        unless observed.instance_of?(SourceAcknowledgment) && observed.matches?(self)
          raise LifecycleError.new("source_acknowledgment_mismatch"), cause: nil
        end
        observed
      end

      def owned_write
        previous = @owned_write
        @owned_write = true
        yield
      ensure
        @owned_write = previous
      end

      def enforce_owned_write
        if !@owned_write && (new_record? || (changes_to_save.keys & (IMMUTABLE + LIFECYCLE)).any?)
          raise LifecycleError.new("intent_write_requires_lifecycle"), cause: nil
        end
      end

      def immutable_snapshot
        errors.add(:base, "request snapshot cannot change") if persisted? && (changes_to_save.keys & IMMUTABLE).any?
        return if persisted?
        if request_body.is_a?(String) && request_body.bytesize <= Submission::MAX_BYTES
          errors.add(:request_hash, "does not match request bytes") unless Digest::SHA256.hexdigest(request_body) == request_hash
        else
          errors.add(:request_body, "exceeds supported size")
        end
      end
    end
  end
end
