# frozen_string_literal: true

require_relative "lib/myinvois_connector/version"

Gem::Specification.new do |spec|
  spec.name = "einvoice-lhdn"
  spec.version = MyInvoisConnector::VERSION
  spec.authors = ["VirtualSpirit"]
  spec.summary = "Reusable MyInvois protocol primitives"
  spec.description = "Exact-byte document envelopes and intermediary authentication/read APIs for MyInvois integrations."
  spec.homepage = "https://github.com/virtualspirit/einvoice-lhdn"
  spec.required_ruby_version = ">= 3.0.3"
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "db/migrate/*.rb", "docs/**/*.md", "README.md"] }
  spec.require_paths = ["lib"]
  spec.metadata["allowed_push_host"] = "https://private.invalid"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.add_dependency "faraday", ">= 2.7", "< 3"
end
