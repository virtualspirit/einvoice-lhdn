# frozen_string_literal: true

class CreateLhdnSubmissionIntents < ActiveRecord::Migration[7.0]
  def change
    create_table :lhdn_submission_intents do |t|
      t.string :intent_uuid, null: false
      t.string :tenant_key, null: false
      t.string :environment, null: false
      t.string :source_reference, null: false
      t.string :source_digest, null: false
      t.text :request_body, null: false
      t.string :request_hash, null: false
      t.jsonb :code_numbers, null: false
      t.string :state, null: false, default: "awaiting_source"
      t.string :acknowledgment
      t.datetime :attempted_at
      t.string :submission_uid
      t.jsonb :receipt_data
      t.string :last_error_code
      t.timestamps
    end
    add_index :lhdn_submission_intents, :intent_uuid, unique: true
    add_index :lhdn_submission_intents, [:tenant_key, :environment, :state, :id], name: "idx_lhdn_intents_work"
    add_index :lhdn_submission_intents, [:tenant_key, :environment, :source_reference], name: "idx_lhdn_intents_source"
    add_check_constraint :lhdn_submission_intents, "environment IN ('sandbox', 'production')", name: "lhdn_intents_environment"
    add_check_constraint :lhdn_submission_intents, "state IN ('awaiting_source', 'ready', 'attempting', 'accepted', 'rejected', 'uncertain')", name: "lhdn_intents_state"
  end
end
