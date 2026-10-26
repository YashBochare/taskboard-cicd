#!/bin/bash
# Removes everything provision.sh created so the project stops consuming credits.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/outputs.env"
export AWS_REGION AWS_PAGER=""

echo "Terminating instances $APP_ID $JENKINS_ID"
for alloc in $(aws ec2 describe-addresses --filters Name=tag:Project,Values=taskboard --query 'Addresses[].AllocationId' --output text); do
  assoc=$(aws ec2 describe-addresses --allocation-ids "$alloc" --query 'Addresses[0].AssociationId' --output text)
  [ "$assoc" != "None" ] && aws ec2 disassociate-address --association-id "$assoc"
  aws ec2 release-address --allocation-id "$alloc" && echo "Released Elastic IP $alloc"
done
aws ec2 terminate-instances --instance-ids "$APP_ID" "$JENKINS_ID" >/dev/null
aws ec2 wait instance-terminated --instance-ids "$APP_ID" "$JENKINS_ID"

aws ec2 delete-security-group --group-id "$JENKINS_SG" && echo "Deleted $JENKINS_SG"
aws ec2 delete-security-group --group-id "$APP_SG" && echo "Deleted $APP_SG"

aws ecr delete-repository --repository-name taskboard --force >/dev/null && echo "Deleted ECR repository"
aws ssm delete-parameter --name /taskboard/jenkins-admin-password && echo "Deleted SSM parameter"

for role in taskboard-app-role taskboard-jenkins-role; do
  aws iam remove-role-from-instance-profile --instance-profile-name $role --role-name $role
  aws iam delete-instance-profile --instance-profile-name $role
  for p in $(aws iam list-attached-role-policies --role-name $role --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name $role --policy-arn "$p"
  done
  for p in $(aws iam list-role-policies --role-name $role --query 'PolicyNames' --output text); do
    aws iam delete-role-policy --role-name $role --policy-name "$p"
  done
  aws iam delete-role --role-name $role && echo "Deleted IAM role $role"
done
echo "Teardown complete."
