#!/bin/bash

# Incus container disabling and deletion script. This should be run daily via a root cron job.

# Configuration
LOG_FILE="/var/log/disabled-containers.log"
TODAY=$(date +%Y-%m-%d)

# One month ago relative to today (used for deletion check)
# We calculate "Expiry + 1 Month <= Today" which is the same as "Expiry <= Today - 1 Month"
ONE_MONTH_AGO=$(date -d "-1 month" +%Y-%m-%d)

echo "--- Running Incus cleanup tasks: $TODAY ---" >> "$LOG_FILE"

# Loop through ALL containers (regardless of status)
for container in $(incus list --format csv -c n); do

    # 1. Grab Metadata
    EXPIRY=$(incus config get "$container" user.expiry 2>/dev/null)
    NO_DETACH=$(incus config get "$container" user.nogpudetach 2>/dev/null)
    STATUS=$(incus info "$container" | grep "Status:" | awk '{print tolower($2)}')

    # Default NO_DETACH to true if undefined
    [ -z "$NO_DETACH" ] && NO_DETACH="true"

    # Skip if no expiry is set
    [[ -z "$EXPIRY" ]] && continue

    # --- PHASE A: Expiry logic for running containers ---
    if [[ "$STATUS" == "running" ]]; then
        if [[ "$TODAY" > "$EXPIRY" || "$TODAY" == "$EXPIRY" ]]; then
            echo "$TODAY: Expired - Disabling $container" >> "$LOG_FILE"

            # Stop the container and disable autostart
            incus stop "$container" --force
            incus config set "$container" boot.autostart false

            # Check GPU detachment policy
            if [[ "$NO_DETACH" == "false" ]]; then
                echo "$TODAY: Removing GPU from $container..." >> "$LOG_FILE"
                incus config device remove "$container" gpu0 2>/dev/null
            fi
        fi
    fi

    # --- PHASE B: Deletion logic ---
    if [[ "$STATUS" == "stopped" ]]; then
        # If Today >= Expiry + 1 month
        # This is equivalent to checking if Expiry is older than ONE_MONTH_AGO
        if [[ "$EXPIRY" < "$ONE_MONTH_AGO" || "$EXPIRY" == "$ONE_MONTH_AGO" ]]; then
            echo "$TODAY: DELETING $container (Expired > 1 month ago on $EXPIRY)" >> "$LOG_FILE"
            incus delete "$container"
        fi
    fi

done
