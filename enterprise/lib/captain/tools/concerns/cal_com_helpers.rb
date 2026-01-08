# frozen_string_literal: true

module Captain
  module Tools
    module Concerns
      module CalComHelpers
        extend ActiveSupport::Concern

        # Cal.com API v2 base URL
        CALCOM_API_BASE = 'https://api.cal.com/v2'

        # Default Cal.com API version
        CALCOM_API_VERSION = '2024-08-13'

        # Fetches the Cal.com user's timezone from their profile
        # @param conversation [Conversation] the current conversation
        # @return [String, nil] the user's timezone (e.g., 'America/Chicago') or nil if unavailable
        def get_calcom_timezone(conversation)
          hook = find_calcom_hook(conversation)
          return nil unless hook&.enabled?

          api_key = get_calcom_api_key(hook)
          return nil if api_key.blank?

          fetch_user_timezone(api_key)
        rescue StandardError => e
          ChatwootExceptionTracker.new(e).capture_exception
          nil
        end

        private

        # Finds the Cal.com integration hook for the account
        # @param conversation [Conversation] the current conversation
        # @return [Integrations::Hook, nil] the hook or nil
        def find_calcom_hook(conversation)
          conversation.account.hooks.find_by(app_id: 'cal_com')
        end

        # Retrieves the API key from the Cal.com hook
        # @param hook [Integrations::Hook] the Cal.com hook
        # @return [String, nil] the API key or nil
        def get_calcom_api_key(hook)
          hook&.settings&.dig('api_key')
        end

        # Fetches user timezone from Cal.com API
        # @param api_key [String] the Cal.com API key
        # @return [String, nil] the timezone or nil
        def fetch_user_timezone(api_key)
          response = calcom_api_request(:get, '/me', api_key)
          return nil unless response[:success]

          response.dig(:data, 'data', 'timeZone')
        end

        # Makes a request to the Cal.com API
        # @param method [Symbol] HTTP method (:get, :post, :delete, etc.)
        # @param path [String] API path (e.g., '/me', '/bookings')
        # @param api_key [String] the Cal.com API key
        # @param body [Hash, nil] request body for POST/PUT requests
        # @return [Hash] { success: Boolean, data: Hash or nil, error: String or nil }
        # @param api_version [String, nil] specific API version for the endpoint
        # @return [Hash] { success: Boolean, data: Hash or nil, error: String or nil }
        def calcom_api_request(method, path, api_key, body = nil, api_version = nil)
          uri = URI("#{CALCOM_API_BASE}#{path}")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true

          request = build_calcom_request(method, uri, api_key, body, api_version)
          response = http.request(request)
          parse_calcom_response(response)
        end

        # Builds the HTTP request with proper Cal.com headers
        def build_calcom_request(method, uri, api_key, body, api_version)
          request_class = {
            get: Net::HTTP::Get,
            post: Net::HTTP::Post,
            delete: Net::HTTP::Delete,
            patch: Net::HTTP::Patch
          }[method] || Net::HTTP::Get

          request = request_class.new(uri)
          request['Authorization'] = "Bearer #{api_key}"
          request['Content-Type'] = 'application/json'
          request['User-Agent'] = 'Chatwoot/1.0 (Captain AI Tool)'
          request['cal-api-version'] = api_version || CALCOM_API_VERSION

          request.body = body.to_json if body.present?
          request
        end

        # Parses the Cal.com API response
        def parse_calcom_response(response)
          data = JSON.parse(response.body)

          if response.is_a?(Net::HTTPSuccess)
            { success: true, data: data }
          else
            { success: false, error: data.dig('error', 'message') || data['message'] || 'Unknown error' }
          end
        rescue JSON::ParserError => e
          { success: false, error: "Failed to parse response: #{e.message}" }
        end
      end
    end
  end
end
