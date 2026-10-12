# frozen_string_literal: true

require "faraday"
require "json"
require "bigdecimal"
require "uri"
require "time"
require "thread"
require_relative "errors"
require_relative "environments"
require_relative "document_details"

module MyInvoisConnector
  # Protocol mechanism only. The host supplies authorized taxpayer context.
  # No tax-document mutation, automatic retry or request logging is provided.
  class ReadClient
    MAX_RESPONSE_BYTES = 2_000_000
    ID_TYPES = %w[NRIC PASSPORT BRN ARMY].freeze

    attr_reader :environment

    def initialize(client_id:, client_secret:, represented_taxpayer:, environment: :sandbox,
                   identity_connection: nil, api_connection: nil,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @hosts = Environments.fetch(environment)
      @environment = environment
      @client_id = nonempty_string(client_id).dup.freeze
      @client_secret = nonempty_string(client_secret).dup.freeze
      taxpayer = nonempty_string(represented_taxpayer)
      unless taxpayer.ascii_only? && taxpayer.match?(/\A[A-Za-z0-9:]+\z/)
        raise ArgumentError, "invalid represented taxpayer header"
      end
      @represented_taxpayer = taxpayer.dup.freeze
      @identity = identity_connection || build_connection(@hosts.fetch(:identity))
      @api = api_connection || build_connection(@hosts.fetch(:api))
      @clock = clock
      @token_mutex = Mutex.new
      @token = nil
      @token_expires_at = 0
    end

    def inspect
      "#<MyInvoisConnector::ReadClient environment=#{environment} credentials=[FILTERED] taxpayer=[FILTERED]>"
    end

    def submission_status(submission_uid:, page: 1, page_size: 100)
      uid = identifier(submission_uid)
      unless page.is_a?(Integer) && page.positive? && page_size.is_a?(Integer) && page_size.between?(1, 100)
        raise ArgumentError, "invalid submission pagination"
      end
      data = get_json("/api/v1.0/documentsubmissions/#{uid}", pageNo: page, pageSize: page_size)
      unless data["submissionUid"] == uid && data["documentSummary"].is_a?(Array)
        raise ProtocolError.new("submission_identity_or_summary_invalid"), cause: nil
      end
      data
    end

    def document_details(uuid:)
      uid = identifier(uuid)
      data = get_json("/api/v1.0/documents/#{uid}/details")
      DocumentDetails.new(data: data, environment: environment, expected_uuid: uid)
    end

    def verify_tin(tin:, id_type:, id_value:)
      number = identifier(tin)
      raise ArgumentError, "unsupported identity type" unless ID_TYPES.include?(id_type)
      value = nonempty_string(id_value)
      get_response("/api/v1.0/taxpayer/validate/#{number}", idType: id_type, idValue: value)
      true
    rescue NotFoundError
      false
    end

    # Caller must use details observed in this environment; no readiness claim.
    def validation_url(details)
      return unless details.is_a?(DocumentDetails) && details.environment == environment && details["status"] == "Valid"
      uuid = details["uuid"]
      long_id = details["longId"]
      return unless uuid.is_a?(String) && !uuid.empty? && long_id.is_a?(String) && !long_id.empty?

      "#{@hosts.fetch(:portal)}/#{path_component(uuid)}/share/#{path_component(long_id)}".freeze
    end

    private

    def nonempty_string(value)
      unless value.is_a?(String) && value.valid_encoding? && !value.strip.empty?
        raise ArgumentError, "required string is missing or invalid"
      end
      value
    end

    def identifier(value)
      value = nonempty_string(value)
      raise ArgumentError, "invalid provider identifier" unless value.ascii_only? && value.match?(/\A[A-Za-z0-9]+\z/)
      value
    end

    def path_component(value)
      URI.encode_www_form_component(value).gsub("+", "%20")
    end

    def build_connection(url)
      Faraday.new(url: url, ssl: { verify: true }) do |connection|
        connection.options.open_timeout = 3
        connection.options.timeout = 8
        connection.adapter Faraday.default_adapter
      end
    end

    def get_json(path, params = {})
      parse_json(get_response(path, params).body)
    end

    def get_response(path, params = {})
      token = access_token
      response = @api.get(path, params) do |request|
        request.headers["Accept"] = "application/json"
        request.headers["Authorization"] = "Bearer #{token}"
      end
      check_status(response)
      response
    rescue Faraday::Error
      raise NetworkError.new("provider_network_error"), cause: nil
    end

    def access_token
      @token_mutex.synchronize do
        return @token if @token && @clock.call < @token_expires_at

        started_at = @clock.call
        response = @identity.post("/connect/token") do |request|
          request.headers["Content-Type"] = "application/x-www-form-urlencoded"
          request.headers["Accept"] = "application/json"
          request.headers["onbehalfof"] = @represented_taxpayer
          request.body = URI.encode_www_form(
            client_id: @client_id, client_secret: @client_secret,
            grant_type: "client_credentials", scope: "InvoicingAPI"
          )
        end
        check_status(response, authentication: true)
        data = parse_json(response.body)
        token = data["access_token"]
        lifetime = data["expires_in"]
        unless token.is_a?(String) && token.match?(/\A[\x21-\x7E]+\z/) &&
               data["token_type"].to_s.casecmp("Bearer").zero? &&
               lifetime.is_a?(Integer) && lifetime.positive?
          raise ProtocolError.new("invalid_token_response"), cause: nil
        end
        expires_at = started_at + lifetime - [60, lifetime * 0.1].min
        if @clock.call >= expires_at
          raise AuthenticationError.new("token_expired_on_arrival"), cause: nil
        end
        @token = token.dup.freeze
        @token_expires_at = expires_at
        @token
      end
    rescue Faraday::Error
      raise NetworkError.new("authentication_network_error"), cause: nil
    end

    def check_status(response, authentication: false)
      return if response.status == 200

      status = response.status
      if status == 401 && !authentication
        @token_mutex.synchronize { @token = nil; @token_expires_at = 0 }
      end
      klass = case status
              when 429 then RateLimitError
              when 401 then AuthenticationError
              when 403 then AuthorizationError
              when 404 then NotFoundError
              when 400, 422 then authentication ? AuthenticationError : InvalidRequestError
              else ProviderError
              end
      klass = AuthenticationError if authentication && status.between?(400, 499) && status != 429
      raise klass.new("provider_http_#{status}", status: status,
                      retry_after: retry_after(response.headers["retry-after"])), cause: nil
    end

    def parse_json(body)
      unless body.is_a?(String) && body.bytesize <= MAX_RESPONSE_BYTES
        raise ProtocolError.new("response_size_invalid"), cause: nil
      end
      data = JSON.parse(body, freeze: true, decimal_class: BigDecimal)
      raise ProtocolError.new("response_object_required"), cause: nil unless data.is_a?(Hash)
      data
    rescue JSON::ParserError, EncodingError
      raise ProtocolError.new("response_json_invalid"), cause: nil
    end

    def retry_after(value)
      return unless value.is_a?(String) && !value.empty?
      return value.to_i if value.match?(/\A\d+\z/)
      [(Time.httpdate(value) - Time.now).ceil, 0].max
    rescue ArgumentError
      nil
    end
  end
end
