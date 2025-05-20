#!/bin/bash
DESTINATION=$1

# Create PostgreSQL directory
mkdir -p $DESTINATION/postgresql

# Create enterprise mountpoint
mkdir -p $DESTINATION/enterprise

# Create data dirs
sudo chmod -R 777 $DESTINATION/config

# Change ownership to current user and set restrictive permissions for security
sudo chown -R odoousr:odoousr $DESTINATION
sudo chmod -R 700 $DESTINATION  # Only the user has access

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
find $DESTINATION -type f -exec chmod 644 {} \;
find $DESTINATION -type d -exec chmod 755 {} \;
