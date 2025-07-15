#!/bin/bash
DESTINATION=$1

# Create PostgreSQL directory
mkdir -p $DESTINATION/database

# Create mountpoints
mkdir -p $DESTINATION/enterprise

# Change ownership to current user and set restrictive permissions for security
sudo chown -R odoousr:odoousr $DESTINATION
# sudo chmod 700 $DESTINATION  # Only the user has access

chmod -R 777 addons
chmod -R 777 config
chmod -R 777 database
chmod -R 777 enterprise
chmod -R 777 l10n_ve
chmod -R 777 entrypoint.sh

# Check if running on macOS
if [[ "$OSTYPE" == "darwin"* ]]; then
  echo "Running on macOS. Skipping inotify configuration."
else
  # System configuration
  if grep -qF "fs.inotify.max_user_watches" /etc/sysctl.conf; then
    echo $(grep -F "fs.inotify.max_user_watches" /etc/sysctl.conf)
  else
    echo "fs.inotify.max_user_watches = 524288" | sudo tee -a /etc/sysctl.conf
  fi
  sudo sysctl -p
fi

# Set file and directory permissions after installation
echo 'Set file and directory permissions after installation'
# find $DESTINATION -type f -exec chmod 644 {} \;
# find $DESTINATION -type d -exec chmod 755 {} \;
