# frozen_string_literal: true

module MyInvoisConnector
  module Environments
    HOSTS = {
      sandbox: {
        identity: "https://preprod-api.myinvois.hasil.gov.my",
        api: "https://preprod-api.myinvois.hasil.gov.my",
        portal: "https://preprod.myinvois.hasil.gov.my"
      }.freeze,
      production: {
        identity: "https://api.myinvois.hasil.gov.my",
        api: "https://api.myinvois.hasil.gov.my",
        portal: "https://myinvois.hasil.gov.my"
      }.freeze
    }.freeze

    def self.fetch(environment)
      HOSTS.fetch(environment) { raise ArgumentError, "unsupported environment" }
    end
  end
end
