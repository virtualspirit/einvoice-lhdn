# frozen_string_literal: true

module MyInvoisConnector
  class Error < StandardError
    attr_reader :code, :status, :retry_after

    def initialize(code, status: nil, retry_after: nil)
      @code = code
      @status = status
      @retry_after = retry_after
      super(code)
    end
  end

  class AuthenticationError < Error; end
  class AuthorizationError < Error; end
  class RateLimitError < Error; end
  class ProviderError < Error; end
  class ProtocolError < Error; end
  class NetworkError < Error; end
  class NotFoundError < Error; end
  class InvalidRequestError < Error; end
  class UncertainResultError < Error; end
  class DuplicateSubmissionError < UncertainResultError; end
end
