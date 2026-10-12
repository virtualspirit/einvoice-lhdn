# frozen_string_literal: true

# Optional activation. Ordinary connector requires do not load Rails or Plugins.
require "logger"
require "active_record"
require "rails"
require "rails/engine"
require "plugins"
require "state_machines-activerecord"
require_relative "../myinvois_connector"

module MyInvoisConnector
  module Persistence
    extend ::Plugins::Decorators::ConfigBuilder

    autoload :Record, "myinvois_connector/persistence/record"
    autoload :SubmissionIntent, "myinvois_connector/persistence/submission_intent"
    autoload :SourceAcknowledgment, "myinvois_connector/persistence/source_acknowledgment"
    autoload :Dispatcher, "myinvois_connector/persistence/dispatcher"

    class LifecycleError < MyInvoisConnector::Error; end

    def self.configure(application_record_base:)
      raise LifecycleError.new("record_base_already_resolved"), cause: nil if @record_base
      unless application_record_base.is_a?(String) && application_record_base.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)
        raise ArgumentError, "abstract record class name is required"
      end
      @configuration = config_builder(application_record_base: application_record_base.dup.freeze)
    end

    def self.record_base!
      @record_base ||= begin
        @configuration ||= config_builder(application_record_base: "ActiveRecord::Base")
        base = @configuration.get(:application_record_base).constantize
        unless base.is_a?(Class) && base <= ActiveRecord::Base && (base == ActiveRecord::Base || base.abstract_class?)
          raise LifecycleError.new("record_base_must_be_abstract"), cause: nil
        end
        base
      end
    end
  end
end

require_relative "persistence/engine"
