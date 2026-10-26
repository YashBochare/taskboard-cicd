#!/bin/bash
# Jenkins server bootstrap. Placeholders (__X__) are filled in by provision.sh.
set -euxo pipefail

AWS_REGION=__AWS_REGION__
REPO_URL=__REPO_URL__
ECR_REGISTRY=__ECR_REGISTRY__
APP_INSTANCE_ID=__APP_INSTANCE_ID__
APP_PRIVATE_IP=__APP_PRIVATE_IP__
JENKINS_URL=__JENKINS_URL__

dnf install -y docker git
systemctl enable --now docker

# 2 GB swap so Jenkins, npm and docker builds fit comfortably on a t3.small.
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
fi

# Build the Jenkins controller image from the repository (jenkins/Dockerfile + casc.yaml).
rm -rf /opt/taskboard && git clone --depth 1 "$REPO_URL.git" /opt/taskboard
docker build -t taskboard-jenkins /opt/taskboard/jenkins

ADMIN_PASSWORD=$(aws ssm get-parameter --region "$AWS_REGION" --name /taskboard/jenkins-admin-password \
  --with-decryption --query Parameter.Value --output text)

docker rm -f jenkins || true
docker run -d --name jenkins --restart unless-stopped \
  -p 8080:8080 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add "$(stat -c %g /var/run/docker.sock)" \
  -e JENKINS_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -e AWS_REGION="$AWS_REGION" \
  -e ECR_REGISTRY="$ECR_REGISTRY" \
  -e APP_INSTANCE_ID="$APP_INSTANCE_ID" \
  -e APP_PRIVATE_IP="$APP_PRIVATE_IP" \
  -e JENKINS_URL="$JENKINS_URL" \
  -e REPO_URL="$REPO_URL" \
  taskboard-jenkins
