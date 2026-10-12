# frozen_string_literal: true

require_relative "../persistence"
require_relative "../client"

module MyInvoisConnector
  module Persistence
    # Explicit unmounted mechanism. The host must select authorized taxpayer
    # credentials and enforce Staff permissions, readiness and signing first.
    class Dispatcher
      def self.call(intent:, client:, source_owner:)
        unless intent.instance_of?(SubmissionIntent) && intent.persisted? && client.is_a?(Client)
          raise ArgumentError, "persisted intent and explicit write client are required"
        end
        unless client.environment.to_s == intent.environment
          raise LifecycleError.new("dispatch_environment_mismatch"), cause: nil
        end
        begin
          submission = Submission.restore(body: intent.request_bytes)
        rescue ArgumentError
          raise LifecycleError.new("dispatch_snapshot_invalid"), cause: nil
        end
        unless Digest::SHA256.hexdigest(submission.body) == intent.request_hash &&
            submission.documents.map(&:code_number) == intent.code_numbers
          raise LifecycleError.new("dispatch_snapshot_invalid"), cause: nil
        end
        return intent unless intent.claim!(source_owner: source_owner)

        # claim! has committed; neither source nor intent transaction encloses
        # transport. A repeat call cannot send an attempting/uncertain intent.
        begin
          receipt = client.submit(submission: submission)
          intent.record_receipt!(receipt: receipt)
        rescue MyInvoisConnector::Error => error
          retain_uncertainty(intent, error.code)
          raise
        rescue StandardError
          retain_uncertainty(intent, "dispatch_result_unrecorded")
          raise LifecycleError.new("dispatch_result_unrecorded"), cause: nil
        end
        intent
      end

      def self.retain_uncertainty(intent, code)
        intent.mark_uncertain!(code: code)
      rescue StandardError
        # A store outage may prevent recording the observation. The committed
        # attempting state remains retained and cannot authorize another send.
        nil
      end
      private_class_method :retain_uncertainty
    end
  end
end
