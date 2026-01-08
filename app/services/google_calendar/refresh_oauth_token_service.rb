class GoogleCalendar::RefreshOauthTokenService
  pattr_initialize [:hook!]

  def access_token
    puts "[RefreshOauthTokenService] access_token called for hook_id=#{hook.id}"
    puts "[RefreshOauthTokenService] Current settings: expires_at=#{settings[:expires_at]}, access_token=#{settings[:access_token]&.first(20)}..."
    puts "[RefreshOauthTokenService] refresh_token present? #{settings[:refresh_token].present?}"

    expired = access_token_expired?
    puts "[RefreshOauthTokenService] access_token_expired? => #{expired}"

    unless expired
      puts '[RefreshOauthTokenService] Token NOT expired, returning existing access_token'
      return settings[:access_token]
    end

    puts '[RefreshOauthTokenService] Token IS expired, starting refresh process...'
    retries ||= 0
    refresh_tokens
    new_token = hook.reload.settings.with_indifferent_access[:access_token]
    puts "[RefreshOauthTokenService] Successfully refreshed! New token: #{new_token&.first(20)}..."
    new_token
  rescue StandardError => e
    retries += 1
    puts "[RefreshOauthTokenService] ERROR during refresh (attempt #{retries}): #{e.class} - #{e.message}"
    puts "[RefreshOauthTokenService] Backtrace: #{e.backtrace&.first(5)&.join("\n")}"
    if retries < 3
      puts "[RefreshOauthTokenService] Retrying... (#{retries}/3)"
      hook.reload
      @settings = nil
      retry
    end
    puts '[RefreshOauthTokenService] All retries exhausted, re-raising error'
    raise
  end

  def access_token_expired?
    expiry = settings[:expires_at]
    puts "[RefreshOauthTokenService] access_token_expired? checking expiry=#{expiry}"

    if expiry.blank?
      puts '[RefreshOauthTokenService] expiry is blank, returning true (expired)'
      return true
    end

    expiry_time = Time.zone.parse(expiry.to_s)
    current_time = Time.current.utc
    buffer_time = expiry_time - 5.minutes

    puts "[RefreshOauthTokenService] expiry_time=#{expiry_time}, current_time=#{current_time}, buffer_time=#{buffer_time}"
    puts "[RefreshOauthTokenService] current_time >= buffer_time ? #{current_time >= buffer_time}"

    # Adding a 5 minute buffer to avoid race conditions
    current_time >= buffer_time
  end

  private

  def settings
    @settings ||= hook.settings.with_indifferent_access
  end

  def refresh_tokens
    puts '[RefreshOauthTokenService] refresh_tokens starting...'

    oauth_strategy = build_oauth_strategy
    puts '[RefreshOauthTokenService] oauth_strategy built'

    token_service = build_token_service(oauth_strategy)
    puts '[RefreshOauthTokenService] token_service built, calling refresh!...'

    new_token_response = token_service.refresh!
    puts '[RefreshOauthTokenService] refresh! succeeded'
    puts "[RefreshOauthTokenService] new_token_response class: #{new_token_response.class}"

    raw_hash = new_token_response.to_hash
    puts "[RefreshOauthTokenService] raw_hash keys: #{raw_hash.keys}"
    puts "[RefreshOauthTokenService] raw_hash: #{raw_hash.inspect}"

    new_tokens = raw_hash.slice(:access_token, :refresh_token, :expires_at)
    puts "[RefreshOauthTokenService] sliced new_tokens: #{new_tokens.inspect}"

    update_hook_settings(new_tokens)
    puts '[RefreshOauthTokenService] hook settings updated successfully'
  end

  def update_hook_settings(new_tokens)
    puts "[RefreshOauthTokenService] update_hook_settings called with: #{new_tokens.inspect}"

    new_settings = {
      access_token: new_tokens[:access_token],
      refresh_token: new_tokens[:refresh_token] || settings[:refresh_token],
      expires_at: Time.at(new_tokens[:expires_at]).utc.to_s
    }
    puts "[RefreshOauthTokenService] new_settings to save: #{new_settings.inspect}"

    hook.settings = new_settings
    hook.save!
    puts '[RefreshOauthTokenService] hook.save! completed'
  end

  def build_oauth_strategy
    app_id = GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_ID', nil)
    app_secret = GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_SECRET', nil)

    puts "[RefreshOauthTokenService] build_oauth_strategy: app_id=#{app_id&.first(10)}..., app_secret=#{app_secret.present? ? 'present' : 'MISSING'}"

    OmniAuth::Strategies::GoogleOauth2.new(nil, app_id, app_secret)
  end

  def build_token_service(oauth_strategy)
    puts "[RefreshOauthTokenService] build_token_service: access_token=#{settings[:access_token]&.first(20)}..., refresh_token=#{settings[:refresh_token]&.first(20)}..."

    OAuth2::AccessToken.new(
      oauth_strategy.client,
      settings[:access_token],
      refresh_token: settings[:refresh_token]
    )
  end
end
