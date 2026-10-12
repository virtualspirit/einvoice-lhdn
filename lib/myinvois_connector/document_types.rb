# frozen_string_literal: true

module MyInvoisConnector
  module DocumentTypes
    CODES = {
      invoice: "01",
      credit_note: "02",
      debit_note: "03",
      refund_note: "04",
      self_billed_invoice: "11",
      self_billed_credit_note: "12",
      self_billed_debit_note: "13",
      self_billed_refund_note: "14"
    }.freeze

    def self.code(name)
      CODES.fetch(name) { raise ArgumentError, "unsupported document type" }
    end
  end
end
