class GoogleCalendar::CallbacksController < ApplicationController
  include GoogleCalendarConcern

  def show
    @response = google_calendar_client.auth_code.get_token(
      oauth_code,
      redirect_uri: "#{base_url}/google_calendar/callback"
    )

    handle_response
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    redirect_to "#{base_url}/app/accounts/#{account.id}/settings/integrations/google_calendar?error=true"
  end

  private

  def handle_response
    hook = account.hooks.find_or_initialize_by(app_id: 'google_calendar')
    hook.assign_attributes(
      status: 'enabled',
      settings: {
        access_token: parsed_body['access_token'],
        refresh_token: parsed_body['refresh_token'],
        expires_at: Time.current.utc + parsed_body['expires_in'].to_i.seconds
      }
    )
    hook.save!

    redirect_to google_calendar_redirect_uri
  end

  def google_calendar_redirect_uri
    "#{base_url}/app/accounts/#{account.id}/settings/integrations/google_calendar"
  end

  def account
    @account ||= account_from_signed_id
  end

  def account_from_signed_id
    raise ActionController::BadRequest, 'Missing state variable' if params[:state].blank?

    located_account = GlobalID::Locator.locate_signed(params[:state])
    raise 'Invalid or expired state' if located_account.nil?

    located_account
  end

  def oauth_code
    params[:code]
  end

  def base_url
    ENV.fetch('FRONTEND_URL', 'http://localhost:3000')
  end

  def parsed_body
    @parsed_body ||= @response.response.parsed
  end
end
