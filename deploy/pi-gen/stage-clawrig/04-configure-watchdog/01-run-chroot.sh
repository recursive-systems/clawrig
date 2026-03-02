#!/bin/bash
set -e

# Enable the gateway watchdog timer (checks every 2 minutes)
systemctl enable clawrig-gateway-watchdog.timer

# Enable the daily self-repair timer (runs at 5 AM)
systemctl enable clawrig-daily-repair.timer
