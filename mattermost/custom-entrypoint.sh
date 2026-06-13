#!/bin/sh
# Custom entrypoint for rheens/mattermost-app:v11.3.0
# Modified to run as ROOT (no su/drop-root) so PVC writes work
# Based on rheens/entrypoint.sh + priv-entrypoint.sh merged

MM_CONFIG="/mattermost/config/config.json"
MM_CONFIG_TMP="${MM_CONFIG}.tmp"

generate_salt() {
  tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32
}

echo "Initializing Mattermost..."

# Create config if missing
if [ ! -f "$MM_CONFIG" ]; then
  echo "No configuration file $MM_CONFIG, creating a new one..."
  
  # Generate salt values
  PUBLIC_LINK_SALT=$(generate_salt)
  INVITE_SALT=$(generate_salt)
  PASSWORD_RESET_SALT=$(generate_salt)
  AT_REST_ENCRYPT_KEY=$(generate_salt)

  jq \
    --arg plsalt "$PUBLIC_LINK_SALT" \
    --arg isalt "$INVITE_SALT" \
    --arg prsalty "$PASSWORD_RESET_SALT" \
    --arg arekey "$AT_REST_ENCRYPT_KEY" \
    '.LogSettings.EnableConsole = true
     | .LogSettings.ConsoleLevel = "ERROR"
     | .FileSettings.Directory = "/mattermost/data/"
     | .FileSettings.EnablePublicLink = true
     | .FileSettings.PublicLinkSalt = $plsalt
     | .EmailSettings.SendEmailNotifications = false
     | .EmailSettings.FeedbackEmail = ""
     | .EmailSettings.SMTPServer = ""
     | .EmailSettings.SMTPPort = ""
     | .EmailSettings.InviteSalt = $isalt
     | .EmailSettings.PasswordResetSalt = $prsalty
     | .RateLimitSettings.Enable = true
     | .SqlSettings.DriverName = "postgres"
     | .SqlSettings.AtRestEncryptKey = $arekey
     | .PluginSettings.Directory = "/mattermost/plugins/"' \
    /mattermost/config.json.save > "$MM_CONFIG_TMP" && mv "$MM_CONFIG_TMP" "$MM_CONFIG"

  echo "Config file created at $MM_CONFIG"
else
  echo "Using existing config file $MM_CONFIG"
fi

# Configure database access from env vars
if [ -n "$MM_SQLSETTINGS_DATASOURCE" ]; then
  echo "Using provided database connection string..."
fi

echo "Starting Mattermost as root..."
exec /mattermost/bin/mattermost server "$@"
