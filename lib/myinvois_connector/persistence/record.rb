# frozen_string_literal: true

require_relative "../persistence"

module MyInvoisConnector
  module Persistence
    class Record < Persistence.record_base!
      self.abstract_class = true
    end
  end
end
