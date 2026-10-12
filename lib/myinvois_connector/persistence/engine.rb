# frozen_string_literal: true

module MyInvoisConnector
  module Persistence
    class Engine < ::Rails::Engine
      isolate_namespace MyInvoisConnector::Persistence
      config.root = File.expand_path("../../..", __dir__)
      extend ::Plugins::EngineCallbacks
    end
  end
end
