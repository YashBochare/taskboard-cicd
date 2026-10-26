#!/bin/bash
# App server bootstrap: Docker runtime only. Deployments arrive from Jenkins via AWS SSM.
set -euxo pipefail
dnf install -y docker
systemctl enable --now docker
