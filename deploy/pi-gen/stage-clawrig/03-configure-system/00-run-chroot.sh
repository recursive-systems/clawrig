#!/bin/bash
set -e

# Set hostname
echo "clawrig" > /etc/hostname
sed -i 's/127.0.1.1.*/127.0.1.1\tclawrig/' /etc/hosts
