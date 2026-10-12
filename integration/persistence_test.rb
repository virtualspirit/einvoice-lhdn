# frozen_string_literal: true

# Requires a host bundle with Rails7.0, Plugins, state_machines-activerecord,
# pg and Minitest. Uses new local task databases only; no app boot/config.
require "bundler/setup"
require "logger"
require "active_record"
require "pg"
require "etc"
require "securerandom"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "minitest/test"
require "webmock/minitest"
WebMock.disable_net_connect!
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "myinvois_connector/persistence"

module PersistenceFixture
  class HostRecord < ActiveRecord::Base
    self.abstract_class = true
  end
  class EngineRecord < ActiveRecord::Base
    self.abstract_class = true
  end
  class Reservation < HostRecord
    self.table_name = "fixture_source_reservations"
  end

  # Trusted fixture role: emulates a committed reservation observation only.
  # Full Finance Manager mutation enforcement is verified separately by host.
  class SourceOwner
    def acknowledgment_for(intent)
      if HostRecord.connection.transaction_open?
        raise MyInvoisConnector::Persistence::LifecycleError.new("source_reservation_not_committed")
      end
      record = Reservation.find_by!(intent_uuid: intent.intent_uuid)
      MyInvoisConnector::Persistence::SourceAcknowledgment.new(**record.attributes.slice(*MyInvoisConnector::Persistence::SourceAcknowledgment::FIELDS.map(&:to_s)).transform_keys(&:to_sym))
    end

    def reserve(intent)
      Reservation.create!(**MyInvoisConnector::Persistence::SourceAcknowledgment::FIELDS.to_h do |field|
        [field, field == :token ? SecureRandom.uuid : intent.public_send(field)]
      end)
    end
  end

  module Databases
    LOCAL = { host: "/tmp", port: 5432, user: Etc.getpwuid.name }.freeze
    CREATED = []
    def self.config(name)
      LOCAL.merge(adapter: "postgresql", database: name, pool: 8, checkout_timeout: 3,
        variables: { statement_timeout: 5000, lock_timeout: 3000 })
    end

    def self.bootstrap
      @maintenance = PG.connect(**LOCAL, dbname: "postgres")
      2.times do
        name = "einvoice_persistence_#{Process.pid}_#{SecureRandom.hex(6)}"
        @maintenance.exec("CREATE DATABASE #{PG::Connection.quote_ident(name)}")
        CREATED << name
      end
      HostRecord.establish_connection(config(CREATED.first))
      HostRecord.connection.create_table(:fixture_source_reservations) do |t|
        MyInvoisConnector::Persistence::SourceAcknowledgment::FIELDS.each { |field| t.string field, null: false }
        t.index :intent_uuid, unique: true
      end
      MyInvoisConnector::Persistence.configure(application_record_base: "PersistenceFixture::EngineRecord")
      require File.expand_path("../db/migrate/20261012000000_create_lhdn_submission_intents", __dir__)
      ActiveRecord::Migration.verbose = false
      CREATED.each do |name|
        EngineRecord.establish_connection(config(name))
        migration = CreateLhdnSubmissionIntents.new
        migration.exec_migration(EngineRecord.connection, :up)
      end
    rescue Exception
      cleanup
      raise
    end

    def self.cleanup
      ActiveRecord::Base.connection_handler.clear_all_connections!
      return unless @maintenance
      CREATED.each { |name| @maintenance.exec("DROP DATABASE #{PG::Connection.quote_ident(name)}") }
      remaining = @maintenance.exec_params("SELECT count(*) FROM pg_database WHERE datname = ANY($1::text[])", ["{#{CREATED.join(',')}}"]).first.fetch("count")
      puts "Persistence database cleanup: #{CREATED.size} dropped; #{remaining} remaining"
      @maintenance.close
      @maintenance = nil
    end
  end
end

PersistenceFixture::Databases.bootstrap
at_exit { PersistenceFixture::Databases.cleanup }

class PersistenceIntegrationTest < Minitest::Test
  include PersistenceFixture
  Persistence = MyInvoisConnector::Persistence
  Intent = Persistence::SubmissionIntent
  Ack = Persistence::SourceAcknowledgment
  HOST = "https://preprod-api.myinvois.hasil.gov.my"
  SUBMIT_URL = "#{HOST}/api/v1.0/documentsubmissions/"

  def dispatch_client(environment: :sandbox)
    stub_request(:post, "#{HOST}/connect/token").to_return(status: 200, body: {
      access_token: "fictional-token", token_type: "Bearer", expires_in: 3600
    }.to_json)
    MyInvoisConnector::Client.new(client_id: "fictional-client", client_secret: "fictional-secret",
      represented_taxpayer: "DEMOONLY", environment: environment)
  end

  def dispatch(client = dispatch_client)
    Persistence::Dispatcher.call(intent: @intent, client: client, source_owner: @owner)
  end

  def test_dispatch_commits_before_transport_and_repeated_delivery_never_resends
    each_storage_mode do
      WebMock.reset!
      ready
      request = stub_request(:post, SUBMIT_URL).with(body: @submission.body).to_return do
        refute HostRecord.connection.transaction_open?
        refute EngineRecord.connection.transaction_open?
        assert Intent.find(@intent.id).attempting?
        { status: 202, body: { submissionUid: "BATCH001",
          acceptedDocuments: [{ uuid: "DEMO001", invoiceCodeNumber: "DEMO-A" }],
          rejectedDocuments: [{ invoiceCodeNumber: "DEMO-B", error: { code: "Invalid" } }] }.to_json }
      end
      assert_same @intent, dispatch
      assert @intent.reload.accepted?
      assert_equal "BATCH001", @intent.submission_uid
      assert_equal 1, @intent.receipt_data.fetch("rejectedDocuments").size
      assert_same @intent, dispatch
      assert_requested request, times: 1
      assert Reservation.exists?(intent_uuid: @intent.intent_uuid)
    end
  end

  def test_dispatch_timeout_retains_uncertainty_and_does_not_resend
    each_storage_mode do
      WebMock.reset!
      ready
      request = stub_request(:post, SUBMIT_URL).to_timeout
      assert_raises(MyInvoisConnector::UncertainResultError) { dispatch }
      assert @intent.reload.uncertain?
      assert_equal "write_transport_uncertain", @intent.last_error_code
      dispatch
      assert_requested request, times: 1
      assert Reservation.exists?(intent_uuid: @intent.intent_uuid)
    end
  end

  def test_dispatch_result_storage_outage_keeps_attempt_and_never_resends
    each_storage_mode do
      WebMock.reset!
      ready
      request = stub_request(:post, SUBMIT_URL).to_return(status: 202, body: {
        submissionUid: "BATCH001", acceptedDocuments: [{ uuid: "DEMO001", invoiceCodeNumber: "DEMO-A" },
          { uuid: "DEMO002", invoiceCodeNumber: "DEMO-B" }], rejectedDocuments: [] }.to_json)
      def @intent.record_receipt!(**)
        raise ActiveRecord::ConnectionNotEstablished, "fictional private storage detail"
      end
      def @intent.mark_uncertain!(**)
        raise ActiveRecord::ConnectionNotEstablished, "fictional private storage detail"
      end
      error = assert_raises(Persistence::LifecycleError) { dispatch }
      assert_equal "dispatch_result_unrecorded", error.code
      assert_nil error.cause
      refute_includes error.full_message, "private storage detail"
      assert @intent.reload.attempting?
      dispatch
      assert_requested request, times: 1
    end
  end

  def test_dispatch_refuses_environment_mismatch_and_open_transactions_before_transport
    each_storage_mode do
      WebMock.reset!
      ready
      request = stub_request(:post, SUBMIT_URL)
      error = assert_raises(Persistence::LifecycleError) { dispatch(dispatch_client(environment: :production)) }
      assert_equal "dispatch_environment_mismatch", error.code
      assert @intent.reload.ready?
      HostRecord.transaction { assert_raises(Persistence::LifecycleError) { dispatch } }
      EngineRecord.transaction { assert_raises(Persistence::LifecycleError) { dispatch } }
      assert @intent.reload.ready?
      assert_nil @intent.attempted_at
      assert_not_requested request
    end
  end

  def test_dispatch_corrupted_storage_never_claims_or_sends
    each_storage_mode do
      WebMock.reset!
      ready
      request = stub_request(:post, SUBMIT_URL)
      # Simulate a storage integrity fault through task-only administrative SQL.
      Intent.connection.execute("UPDATE lhdn_submission_intents SET request_hash = #{Intent.connection.quote('0' * 64)} WHERE id = #{Integer(@intent.id)}")
      @intent.reload
      error = assert_raises(Persistence::LifecycleError) { dispatch }
      assert_equal "dispatch_snapshot_invalid", error.code
      assert @intent.reload.ready?
      assert_nil @intent.attempted_at
      assert_not_requested request
    end
  end

  def each_storage_mode
    [*Databases::CREATED, Databases::CREATED.first].each_with_index do |name, index|
      EngineRecord.connection_specification_name = EngineRecord.name
      EngineRecord.establish_connection(Databases.config(name))
      if index == 2
        EngineRecord.remove_connection
        EngineRecord.connection_specification_name = HostRecord.connection_specification_name
      end
      Intent.reset_column_information
      Intent.delete_all # Task fixture reset only, never a product retention path.
      Reservation.delete_all
      @mode = ["same database, separate pools", "separate database", "same database, shared pool"].fetch(index)
      assert_same HostRecord.connection, EngineRecord.connection if index == 2
      @owner = SourceOwner.new
      @submission = MyInvoisConnector::Submission.new(documents: %w[DEMO-A DEMO-B].map do |code|
        MyInvoisConnector::SubmissionDocument.new(bytes: "<Invoice>Fictional</Invoice>", format: "XML", code_number: code)
      end)
      @intent = Intent.prepare!(tenant_key: "FICTIONAL-A", environment: :sandbox,
        source_reference: "fixture/source/1", source_digest: Digest::SHA256.hexdigest("fictional basis"), submission: @submission)
      assert_equal name, Intent.connection.current_database, @mode
      yield
    end
  end

  def ready
    @owner.reserve(@intent)
    @intent.acknowledge!(source_owner: @owner)
  end

  def receipt(accepted: true, numbers: %w[DEMO-A DEMO-B])
    MyInvoisConnector::SubmissionReceipt.new(data: {
      "submissionUid" => accepted ? "BATCH001" : nil,
      "acceptedDocuments" => accepted ? [{ "uuid" => "DEMO001", "invoiceCodeNumber" => numbers.first }] : [],
      "rejectedDocuments" => (accepted ? numbers.drop(1) : numbers).map { |number| { "invoiceCodeNumber" => number, "error" => { "code" => "Invalid" } } }
    }, code_numbers: numbers)
  end

  def test_prepare_captures_immutable_exact_request_and_safe_inspection
    each_storage_mode do
      assert_equal @submission.body, @intent.request_bytes
      assert_equal Digest::SHA256.hexdigest(@submission.body), @intent.request_hash
      assert_equal %w[DEMO-A DEMO-B], @intent.code_numbers
      assert @intent.request_bytes.frozen?
      assert @intent.awaiting_source?
      refute_includes @intent.inspect, "FICTIONAL-A"
      refute_includes @intent.inspect, "<Invoice>"
      assert_raises(ActiveRecord::RecordInvalid) { @intent.update!(request_body: "changed") }
      assert_equal @submission.body, @intent.reload.request_body
    end
  end

  def test_missing_acknowledgment_and_unavailable_store_never_become_ready
    each_storage_mode do
      assert_raises(ActiveRecord::RecordNotFound) { @intent.acknowledge!(source_owner: @owner) }
      assert @intent.reload.awaiting_source?
      unavailable = Object.new
      def unavailable.acknowledgment_for(*)
        raise MyInvoisConnector::Persistence::LifecycleError.new("source_unavailable")
      end
      assert_raises(Persistence::LifecycleError) { @intent.acknowledge!(source_owner: unavailable) }
      refute @intent.claim!(source_owner: @owner)
      assert_nil @intent.reload.attempted_at
    end
  end

  def test_acknowledgment_is_idempotent_but_every_context_field_is_bound
    each_storage_mode do
      ready
      token = @intent.acknowledgment
      @intent.acknowledge!(source_owner: @owner)
      assert_equal token, @intent.reload.acknowledgment
      Ack::FIELDS.each do |field|
        observation = @owner.acknowledgment_for(@intent)
        data = Ack::FIELDS.to_h { |key| [key, observation.public_send(key)] }.merge(field => "MISMATCH")
        fake = Struct.new(:observation) { def acknowledgment_for(*) = observation }.new(Ack.new(**data))
        assert_raises(Persistence::LifecycleError, field.to_s) { @intent.claim!(source_owner: fake) }
        assert @intent.reload.ready?
      end
    end
  end

  def test_claim_is_durable_once_only_and_no_outer_transaction_is_allowed
    each_storage_mode do
      ready
      Intent.transaction do
        assert_raises(Persistence::LifecycleError) { @intent.claim!(source_owner: @owner) }
      end
      assert @intent.reload.ready?
      HostRecord.transaction do
        assert_raises(Persistence::LifecycleError) { @intent.claim!(source_owner: @owner) }
      end
      assert @intent.reload.ready?
      assert @intent.claim!(source_owner: @owner)
      assert Intent.find(@intent.id).attempting?
      assert @intent.reload.attempted_at
      refute Intent.find(@intent.id).claim!(source_owner: @owner)
    end
  end

  def test_concurrent_claims_have_one_winner
    each_storage_mode do
      ready
      barrier = Queue.new
      threads = 2.times.map do
        Thread.new do
          EngineRecord.connection_pool.with_connection do
            HostRecord.connection_pool.with_connection do
              barrier.pop
              Intent.find(@intent.id).claim!(source_owner: @owner)
            end
          end
        end
      end
      2.times { barrier << true }
      assert_equal [false, true], threads.map(&:value).sort_by(&:to_s), @mode
      assert @intent.reload.attempting?
    ensure
      threads&.each { |thread| thread.kill if thread.alive?; thread.join }
    end
  end

  def test_uncertainty_cannot_reset_or_resend_and_deletion_is_prohibited
    each_storage_mode do
      ready
      @intent.claim!(source_owner: @owner)
      @intent.mark_uncertain!(code: "write_transport_uncertain")
      @intent.mark_uncertain!(code: "result_persistence_failed")
      assert @intent.reload.uncertain?
      refute @intent.claim!(source_owner: @owner)
      assert_raises(Persistence::LifecycleError) { @intent.update!(state: "ready") }
      @intent.reload
      assert_raises(Persistence::LifecycleError) { @intent.update_columns(state: "ready") }
      assert_raises(Persistence::LifecycleError) { @intent.destroy! }
      assert_raises(Persistence::LifecycleError) { @intent.delete }
      assert_raises(ArgumentError) { @intent.mark_uncertain!(code: "private buyer detail") }
    end
  end

  def test_generated_events_and_validation_bypass_cannot_skip_owned_lifecycle
    each_storage_mode do
      assert_raises(Persistence::LifecycleError) { @intent.acknowledge_source! }
      @intent.reload
      @intent.state = "ready"
      assert_raises(Persistence::LifecycleError) { @intent.save!(validate: false) }
      assert @intent.reload.awaiting_source?
      assert_raises(Persistence::LifecycleError) do
        Intent.create!(@intent.attributes.except("id", "created_at", "updated_at").merge("intent_uuid" => SecureRandom.uuid))
      end
    end
  end

  def test_initial_receipt_is_correlated_and_does_not_claim_final_validity
    each_storage_mode do
      ready
      @intent.claim!(source_owner: @owner)
      assert_raises(Persistence::LifecycleError) { @intent.record_receipt!(receipt: receipt(numbers: %w[OTHER-A OTHER-B])) }
      assert @intent.reload.attempting?
      @intent.record_receipt!(receipt: receipt)
      assert @intent.reload.accepted?
      assert_equal "BATCH001", @intent.submission_uid
      assert_equal 1, @intent.receipt_data.fetch("acceptedDocuments").size
      assert_equal 1, @intent.receipt_data.fetch("rejectedDocuments").size
      refute @intent.claim!(source_owner: @owner)
      assert_raises(Persistence::LifecycleError) { @intent.record_receipt!(receipt: receipt) }
    end
  end

  def test_all_rejected_receipt_is_distinct_from_uncertain_acceptance
    each_storage_mode do
      ready
      @intent.claim!(source_owner: @owner)
      @intent.record_receipt!(receipt: receipt(accepted: false))
      assert @intent.reload.rejected?
      assert_nil @intent.submission_uid
      refute @intent.claim!(source_owner: @owner)
    end
  end

  def test_boot_configuration_and_migration_constraints
    each_storage_mode do
      assert_raises(Persistence::LifecycleError) { Persistence.configure(application_record_base: "ActiveRecord::Base") }
      assert_raises(ActiveRecord::StatementInvalid) do
        Intent.connection.execute("UPDATE lhdn_submission_intents SET state = 'valid' WHERE id = #{@intent.id.to_i}")
      end
      assert @intent.reload.awaiting_source?
      assert_equal "lhdn_submission_intents", Intent.table_name
    end
  end

  def test_concrete_constant_cold_loads_with_configured_base
    root = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      require "bundler/setup"
      require "myinvois_connector/persistence"
      class ColdRecord < ActiveRecord::Base
        self.abstract_class = true
        establish_connection(#{Databases.config(Databases::CREATED.first).inspect})
      end
      MyInvoisConnector::Persistence.configure(application_record_base: "ColdRecord")
      require "myinvois_connector/persistence/submission_intent"
      klass = MyInvoisConnector::Persistence::SubmissionIntent
      abort unless klass < ColdRecord && klass.new.awaiting_source?
      abort unless MyInvoisConnector::Persistence::Engine < Rails::Engine
      puts "ok"
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", root, "-e", script)
    assert status.success?, stderr
    assert_equal "ok\n", stdout
  end
end

require "minitest/autorun"
