# Be sure to restart your server when you modify this file.
is_secure = Rails.env.production? || ENV['FORCE_SSL'] == 'true' || ENV['FRONTEND_URL']&.start_with?('https')
Rails.application.config.session_store :cookie_store, key: '_chatwoot_session', same_site: :lax, secure: is_secure
