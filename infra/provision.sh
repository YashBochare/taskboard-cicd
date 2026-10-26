#!/bin/bash
# Provisions the TaskBoard CI/CD infrastructure on AWS with the AWS CLI.
#   ECR repository, IAM roles, security groups, Jenkins EC2 server, app EC2 server, Elastic IPs.
# Usage: REPO_URL=https://github.com/<user>/<repo> infra/provision.sh
set -euo pipefail

export AWS_REGION=${AWS_REGION:-ap-southeast-2}
export AWS_PAGER=""
: "${REPO_URL:?set REPO_URL to the GitHub repository URL}"
PROJECT=taskboard
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/outputs.env"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
TAGS="ResourceType=instance,Tags=[{Key=Project,Value=$PROJECT}"
echo "Account $ACCOUNT_ID  Region $AWS_REGION  VPC $VPC_ID  AMI $AMI"

# ---------- 1. Amazon ECR repository ----------
aws ecr describe-repositories --repository-names $PROJECT >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name $PROJECT \
    --image-scanning-configuration scanOnPush=true \
    --tags Key=Project,Value=$PROJECT >/dev/null
aws ecr put-lifecycle-policy --repository-name $PROJECT --lifecycle-policy-text '{
  "rules":[{"rulePriority":1,"description":"Keep the 10 most recent images",
  "selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},
  "action":{"type":"expire"}}]}' >/dev/null
echo "ECR repository: $ECR_REGISTRY/$PROJECT"

# ---------- 2. IAM roles + instance profiles ----------
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
make_role() { # name, managed policies...
  local name=$1; shift
  aws iam get-role --role-name "$name" >/dev/null 2>&1 || \
    aws iam create-role --role-name "$name" --assume-role-policy-document "$TRUST" \
      --tags Key=Project,Value=$PROJECT >/dev/null
  for p in "$@"; do aws iam attach-role-policy --role-name "$name" --policy-arn "arn:aws:iam::aws:policy/$p"; done
  aws iam get-instance-profile --instance-profile-name "$name" >/dev/null 2>&1 || {
    aws iam create-instance-profile --instance-profile-name "$name" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$name" --role-name "$name"
  }
}
make_role taskboard-app-role AmazonSSMManagedInstanceCore AmazonEC2ContainerRegistryReadOnly
make_role taskboard-jenkins-role AmazonSSMManagedInstanceCore AmazonEC2ContainerRegistryPowerUser

# ---------- 3. Security groups ----------
sg() { # name, description
  aws ec2 describe-security-groups --filters Name=group-name,Values="$1" Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text | grep -v None || \
  aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$1},{Key=Project,Value=$PROJECT}]" \
    --query GroupId --output text
}
allow() { aws ec2 authorize-security-group-ingress "$@" >/dev/null 2>&1 || true; }

JENKINS_SG=$(sg taskboard-jenkins-sg "Jenkins UI for admin IP and GitHub webhooks")
APP_SG=$(sg taskboard-app-sg "TaskBoard web traffic")
MY_IP=$(curl -fs https://checkip.amazonaws.com | tr -d '\n')
allow --group-id "$JENKINS_SG" --ip-permissions "IpProtocol=tcp,FromPort=8080,ToPort=8080,IpRanges=[{CidrIp=$MY_IP/32,Description=Admin}]"
for cidr in $(curl -fs https://api.github.com/meta | python3 -c 'import json,sys;print("\n".join(c for c in json.load(sys.stdin)["hooks"] if ":" not in c))'); do
  allow --group-id "$JENKINS_SG" --ip-permissions "IpProtocol=tcp,FromPort=8080,ToPort=8080,IpRanges=[{CidrIp=$cidr,Description=GitHub-webhooks}]"
done
allow --group-id "$APP_SG" --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=Public-web}]"
echo "Security groups: jenkins=$JENKINS_SG app=$APP_SG (admin IP $MY_IP)"

sleep 10  # let new instance profiles propagate before launching instances

# ---------- 4. App server ----------
launch() { # name, type, sg, profile, userdata-file
  aws ec2 run-instances --image-id "$AMI" --instance-type "$2" \
    --security-group-ids "$3" --iam-instance-profile Name="$4" \
    --user-data "file://$5" \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2 \
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3,Encrypted=true}' \
    --tag-specifications "$TAGS,{Key=Name,Value=$1}]" "ResourceType=volume,Tags=[{Key=Project,Value=$PROJECT}]" \
    --query 'Instances[0].InstanceId' --output text
}
eip_for() { # instance-id, name
  local alloc ip
  alloc=$(aws ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$2},{Key=Project,Value=$PROJECT}]" \
    --query AllocationId --output text)
  aws ec2 associate-address --instance-id "$1" --allocation-id "$alloc" >/dev/null
  aws ec2 describe-addresses --allocation-ids "$alloc" --query 'Addresses[0].PublicIp' --output text
}

APP_ID=$(launch taskboard-app-server t3.micro "$APP_SG" taskboard-app-role "$HERE/app-userdata.sh")
aws ec2 wait instance-running --instance-ids "$APP_ID"
APP_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$APP_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
APP_IP=$(eip_for "$APP_ID" taskboard-app-eip)
echo "App server $APP_ID  private $APP_PRIVATE_IP  public $APP_IP"

# Jenkins may only send SSM commands to this app server.
aws iam put-role-policy --role-name taskboard-jenkins-role --policy-name taskboard-deploy --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
   {\"Effect\":\"Allow\",\"Action\":\"ssm:SendCommand\",\"Resource\":[
      \"arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:instance/$APP_ID\",
      \"arn:aws:ssm:$AWS_REGION::document/AWS-RunShellScript\"]},
   {\"Effect\":\"Allow\",\"Action\":[\"ssm:GetCommandInvocation\",\"ssm:ListCommandInvocations\"],\"Resource\":\"*\"},
   {\"Effect\":\"Allow\",\"Action\":\"ssm:GetParameter\",\"Resource\":\"arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:parameter/taskboard/*\"}]}"

# ---------- 5. Jenkins server ----------
aws ssm get-parameter --name /taskboard/jenkins-admin-password >/dev/null 2>&1 || \
  aws ssm put-parameter --name /taskboard/jenkins-admin-password --type SecureString \
    --value "$(openssl rand -base64 18 | tr -d '/+=')" --description "Jenkins admin password" >/dev/null

JENKINS_ALLOC=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=taskboard-jenkins-eip},{Key=Project,Value=$PROJECT}]" \
  --query AllocationId --output text)
JENKINS_IP=$(aws ec2 describe-addresses --allocation-ids "$JENKINS_ALLOC" --query 'Addresses[0].PublicIp' --output text)
JENKINS_URL="http://$JENKINS_IP:8080/"

USERDATA=$(mktemp)
sed -e "s#__AWS_REGION__#$AWS_REGION#" -e "s#__REPO_URL__#$REPO_URL#" -e "s#__ECR_REGISTRY__#$ECR_REGISTRY#" \
    -e "s#__APP_INSTANCE_ID__#$APP_ID#" -e "s#__APP_PRIVATE_IP__#$APP_PRIVATE_IP#" -e "s#__JENKINS_URL__#$JENKINS_URL#" \
    "$HERE/jenkins-userdata.sh" > "$USERDATA"
JENKINS_ID=$(launch taskboard-jenkins-server t3.small "$JENKINS_SG" taskboard-jenkins-role "$USERDATA")
aws ec2 wait instance-running --instance-ids "$JENKINS_ID"
aws ec2 associate-address --instance-id "$JENKINS_ID" --allocation-id "$JENKINS_ALLOC" >/dev/null
echo "Jenkins server $JENKINS_ID  $JENKINS_URL"

cat > "$OUT" <<EOF
AWS_REGION=$AWS_REGION
ACCOUNT_ID=$ACCOUNT_ID
ECR_REGISTRY=$ECR_REGISTRY
JENKINS_SG=$JENKINS_SG
APP_SG=$APP_SG
APP_ID=$APP_ID
APP_IP=$APP_IP
APP_PRIVATE_IP=$APP_PRIVATE_IP
JENKINS_ID=$JENKINS_ID
JENKINS_IP=$JENKINS_IP
JENKINS_URL=$JENKINS_URL
EOF
echo "Done. Outputs written to $OUT"
