### Parameters

########## Parameters (Start)
# General
clustername="prestocluster" # Name of the EKS cluster
region="us-east-2" # Region to deploy EKS

# CloudFormation
cf_iam_alb_policy_stackname="cf-alb-iam-policy" # Name of the CF stack name of ALB Controller IAM Policy

# EFS
MOUNT_TARGET_GROUP_NAME="presto-eks-efs-group" # Name of the EFS mount target
MOUNT_TARGET_GROUP_DESC="NFS access to Presto on EFS from EKS worker nodes" # EFS mount target description

# EKS
namespace="presto-fargate" # Kubernetes name space for the Presto environment
alb_hostname="prestoeks.myawslearn.tech" # Hostname applied to ALB that will restrict access only to this hostname
alb_certarn="arn:aws:acm:us-east-2:${accountid}:certificate/0fdff309-da80-4326-b1ba-f15844ed7f3f" # SSL/TLS Cert ARN
efs_pod_image="${accountid}.dkr.ecr.us-east-2.amazonaws.com/matthewtan/presto-efs:1.1" # Location of the EFS pod container image
presto_image="${accountid}.dkr.ecr.us-east-2.amazonaws.com/matthewtan/presto-server:1.2" # Location of the Presto container image

# Presto
username1="matthew" # Username to be created in the password.db file
password1="TestPwd" # Password to the above username
########## Parameters (End)