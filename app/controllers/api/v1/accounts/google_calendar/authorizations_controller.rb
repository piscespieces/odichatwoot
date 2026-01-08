class Api::V1::Accounts::GoogleCalendar::AuthorizationsController < Api::V1::Accounts::OauthAuthorizationController
  include GoogleCalendarConcern

  def create
    redirect_url = google_calendar_client.auth_code.authorize_url(
      {
        redirect_uri: "#{base_url}/google_calendar/callback",
        scope: scope,
        response_type: 'code',
        prompt: 'consent',
        access_type: 'offline',
        state: state,
        client_id: GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_ID', nil)
      }
    )

    if redirect_url
      render json: { success: true, url: redirect_url }
    else
      render json: { success: false }, status: :unprocessable_entity
    end
  end
end
