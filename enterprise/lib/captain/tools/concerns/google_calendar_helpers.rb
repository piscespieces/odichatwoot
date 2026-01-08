# frozen_string_literal: true

module Captain
  module Tools
    module Concerns
      module GoogleCalendarHelpers
        extend ActiveSupport::Concern

        private

        def get_calendar_timezone(conversation)
          hook = conversation.account.hooks.find_by(app_id: 'google_calendar')
          return nil unless hook&.enabled?

          token = GoogleCalendar::RefreshOauthTokenService.new(hook: hook).access_token
          return nil if token.blank?

          uri = URI('https://www.googleapis.com/calendar/v3/calendars/primary')
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true

          request = Net::HTTP::Get.new(uri.path)
          request['Authorization'] = "Bearer #{token}"
          request['Content-Type'] = 'application/json'

          response = http.request(request)
          return nil unless response.is_a?(Net::HTTPSuccess)

          data = JSON.parse(response.body)
          data['timeZone']
        rescue StandardError => e
          ChatwootExceptionTracker.new(e).capture_exception
          nil
        end
      end
    end
  end
end
