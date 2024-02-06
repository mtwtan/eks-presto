#!/bin/bash

### How to run this shell script and pass in the account ID parameter (start)
#
#  $ bash env.sh "< account id > < ACCESS KEY > < SECRET >" 
#
### How to run this shell script and pass in the account ID parameter (end)

### Test for account ID parameter passed through else exit from script
echo $# arguments 
if [ "$#" -lt 3 ]; then
    echo "Please make sure you provide 3 parameters: Account ID, 
    IAM user access key, IAM access secret; 
    example: bash env.sh '12345678' 'ACCESSKEY' 'SECRETKEY'";
    exit 1
fi

### Parameters

########## Parameters (Start)

### Global parameters (start)
accountid="${1}" ## AWS Account ID
accesskey="${2}" ## IAM User programmatic access key
secretkey="${3}" ## IAM User programmatic secret key
### Global parameters (end)


########## Parameters (End)

####################### Functions (start) ###############################

### CloudFormation create stack wait function

cf_stack_status () {

  local cf_stackname=${1}

  local vpccfstatus="NOT STARTED"
  local timesec=15
  local timewait=15

  sleep ${timewait}

  echo "CloudFormation Stack ${cf_stackname} Status..."

  while [ "${vpccfstatus}" != "CREATE_COMPLETE" ]
  do
  
    vpccfstatus=$(aws cloudformation describe-stacks \
      --stack-name ${cf_stackname} \
      --region ${region} | jq '.Stacks[].StackStatus' | sed 's/\"//g')

    echo "Status at ${timesec} sec.: ${vpccfstatus}"
    sleep ${timewait}
    timesec=$(($timesec+${timewait}))
  done

  echo "Status at ${timesec} sec.: ${vpccfstatus}"

}

####################### Functions (end) ###############################


# Get parameters from parameters.sh
source ./parameters.sh
efs_pod_image=$(echo $efs_pod_image | sed 's/\//\\\//g')
alb_certarn=$(echo $alb_certarn | sed 's/\//\\\//g')
presto_image=$(echo $presto_image | sed 's/\//\\\//g')

# Create temporary folder
mkdir temp

# Install VPC and EKS Cluster
## Copy template to working yaml
cp environment/eksdeploy.template.yaml temp/eksdeploy.yaml
## Customizing for deployment
sed -i "s/%clustername%/${clustername}/" temp/eksdeploy.yaml
sed -i "s/%region%/${region}/" temp/eksdeploy.yaml
sed -i "s/%namespace%/${namespace}/" temp/eksdeploy.yaml
## Deploy script
eksctl create cluster -f temp/eksdeploy.yaml

# Cluster name
echo "EKS CLuster name: ${clustername}"

# Check EKS Cluster deployment status
ekscluster_status=$(eksctl get cluster \
  -n ${clustername} \
  --region ${region} --output json | jq .[0].Status | sed 's/"//g')

echo "EKS Cluster ${clustername} is ${ekscluster_status}."

# Create Namespace for Presto
kubectl create namespace ${namespace}

## Verify namespace
kubectl get namespace ${namespace}

# Install Helm Chart
curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
helm repo add stable https://charts.helm.sh/stable

# Associate OIDC of cluster to IAM
echo "Associating OIDC of cluster to IAM"
eksctl utils associate-iam-oidc-provider --region=$region --cluster=$clustername --approve


# Create IAM Policy for the AWS Load Balancer Controller

aws cloudformation create-stack \
  --stack-name ${cf_iam_alb_policy_stackname} \
  --region ${region} \
  --template-body file://environment/iam_policy_alb.yaml \
  --capabilities CAPABILITY_IAM

# Check status before moving on
cf_stack_status ${cf_iam_alb_policy_stackname}

policy_arn=$(aws cloudformation describe-stacks \
    --stack-name ${cf_iam_alb_policy_stackname} \
    --region ${region} | jq '.Stacks[].Outputs[]' | jq 'select(.OutputKey=="IAMPolicyRole")' | jq .OutputValue | sed 's/\"//g')

echo "ALB controller Policy ARN: ${policy_arn}"

# Apply ALB IAM Policy to the ALB Controller service

eksctl create iamserviceaccount \
  --cluster=${clustername} \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=${policy_arn} \
  --override-existing-serviceaccounts \
  --approve

# Install the TargetGroupBinding custom resource definitions.
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"

# Add the eks-charts repository.
helm repo add eks https://aws.github.io/eks-charts

vpcid=$(eksctl get cluster ${clustername} -o json | jq .[].ResourcesVpcConfig.VpcId | sed 's/"//g')

# Install ALB controller
helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
  --set clusterName=${clustername} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=${region} \
  --set vpcId=${vpcid} \
  --set image.tag="${LBC_VERSION}" \
  -n kube-system

# Verify k8s CNI is built
kubectl describe daemonset aws-node --namespace kube-system | grep Image | cut -d "/" -f 2

# Build EFS file system for common configuration file

## Get VPC info from EKS cluster
CLUSTER_NAME=${clustername}
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.resourcesVpcConfig.vpcId" --output text)
CIDR_BLOCK=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query "Vpcs[].CidrBlock" --output text)

## Create EFS security group
MOUNT_TARGET_GROUP_ID=$(aws ec2 create-security-group \
  --group-name $MOUNT_TARGET_GROUP_NAME \
  --description "$MOUNT_TARGET_GROUP_DESC" \
  --vpc-id $VPC_ID | jq --raw-output '.GroupId')
aws ec2 authorize-security-group-ingress \
  --group-id $MOUNT_TARGET_GROUP_ID \
  --protocol tcp --port 2049 --cidr $CIDR_BLOCK

## Create an EFS 
FILE_SYSTEM_ID=$(aws efs create-file-system | jq --raw-output '.FileSystemId')

echo "File System ID: $FILE_SYSTEM_ID"

## Waiting for EFS to be fully available
efsstatus="Not Available"
timesec=15
timewait=15

while [ "${efsstatus}" != "available" ]
do


  efsstatus=$(aws efs describe-file-systems \
    --file-system-id $FILE_SYSTEM_ID | jq .FileSystems | jq .[].LifeCycleState | sed 's/"//g')

  echo "Status at ${timesec} sec.: ${efsstatus}"
  sleep ${timewait}
  timesec=$(($timesec+${timewait}))

done

echo "EFS status at ${timesec} sec.: ${efsstatus}"

## Create Mount Target for EFS

#TAG1=tag:kubernetes.io/cluster/$CLUSTER_NAME
TAG1=tag:alpha.eksctl.io/cluster-name
TAG2=tag:kubernetes.io/role/elb
subnets=($(aws ec2 describe-subnets --filters "Name=$TAG1,Values=$CLUSTER_NAME" "Name=$TAG2,Values=1" | jq --raw-output '.Subnets[].SubnetId'))

echo "Creating Mount Targets for EFS..."

for subnet in ${subnets[@]}
do
    echo "creating mount target in " $subnet
    aws efs create-mount-target \
      --file-system-id $FILE_SYSTEM_ID \
      --subnet-id $subnet \
      --security-groups $MOUNT_TARGET_GROUP_ID
done

#MT_NUM=$(aws efs describe-mount-targets \
#  --file-system-id $FILE_SYSTEM_ID | jq --raw-output '.MountTargets[].LifeCycleState' | wc -l)



## Checking Mount Target status

MT_STATUS_JSON_=$(aws efs describe-mount-targets \
  --file-system-id $FILE_SYSTEM_ID)

MT_NUM=$(echo ${MT_STATUS_JSON_} | jq --raw-output '.MountTargets[].LifeCycleState' | wc -l)
LOOPMAX=$((MT_NUM-1))

LOOPCOUNT=0
MT_STATUS_COUNT=0
while [ "$MT_STATUS_COUNT" -lt "$MT_NUM" ]
do
  MT_STATUS_JSON=$(aws efs describe-mount-targets \
  --file-system-id $FILE_SYSTEM_ID)

  MT_STATUS_EA=$(echo $MT_STATUS_JSON | jq --raw-output ".MountTargets[$LOOPCOUNT].LifeCycleState")

  if [ "$MT_STATUS_EA" == "available" ]; then
    MT_STATUS_COUNT=$((MT_STATUS_COUNT+1))
    echo "Number of targets available is: $MT_STATUS_COUNT"
  fi
  echo "Mount Target [ $LOOPCOUNT ] is: $MT_STATUS_EA"

  if [ "$LOOPCOUNT" -eq "$LOOPMAX" ]; then
    LOOPCOUNT=0
  else
    LOOPCOUNT=$((LOOPCOUNT+1))
  fi
  sleep 5
done


# Deploy EFS CSI Driver
## Unnecessary for Fargate
#kubectl apply -k "github.com/kubernetes-sigs/aws-efs-csi-driver/deploy/kubernetes/overlays/stable/?ref=release-1.0"

# Create Persistent Volume
cp k8s/efs-pvc-fargate.template.yaml temp/efs-pvc-fargate.yaml
sed -i "s/%efsid%/$FILE_SYSTEM_ID/" temp/efs-pvc-fargate.yaml
sed -i "s/%namespace%/${namespace}/" temp/efs-pvc-fargate.yaml

kubectl apply -f temp/efs-pvc-fargate.yaml

## Verify PVC
kubectl get pvc -n ${namespace}
kubectl get pv

# Create Presto configuration files and move them to EFS

## Create a pod to connect to EFS
cp k8s/efs-pod.template.yaml temp/efs-pod.yaml
sed -i "s/%namespace%/${namespace}/" temp/efs-pod.yaml
sed -i "s/%region%/${region}/g" temp/efs-pod.yaml
sed -i "s/%efs_pod_image%/${efs_pod_image}/" temp/efs-pod.yaml

kubectl create -f temp/efs-pod.yaml

kubectl -n $namespace rollout status deployment efs-pod

efs_pod_name=$(kubectl -n $namespace get pods \
  --selector=app.kubernetes.io/name=efs-pod \
  -o jsonpath='{.items[*].metadata.name}')

## Copy files to EFS

kubectl exec -n $namespace \
  --tty --stdin $efs_pod_name \
  -- cp /tmp/config.properties.coordinator /efs/config.properties.coordinator

kubectl exec -n $namespace \
  --tty --stdin $efs_pod_name \
  -- cp /tmp/config.properties.worker /efs/config.properties.worker

kubectl exec -n $namespace \
  --tty --stdin $efs_pod_name \
  -- sed -i "s/%region%/us-east-2/g" /tmp/hive.properties

kubectl exec -n $namespace \
  --tty --stdin $efs_pod_name \
  -- cp /tmp/hive.properties /efs/hive.properties

kubectl exec -n $namespace \
  --tty --stdin $efs_pod_name \
  -- cp /tmp/jmx.properties /efs/jmx.properties

kubectl exec -n $namespace \
  --tty --stdin $efs_pod_name \
  -- cp /tmp/jvm.config.coordinator /efs/jvm.config.coordinator

kubectl exec -n $namespace \
  --tty --stdin $efs_pod_name \
  -- cp /tmp/jvm.config.worker /efs/jvm.config.worker

kubectl exec -n $namespace \
  --tty --stdin $efs_pod_name \
  -- cp /tmp/log.properties /efs/log.properties

kubectl exec -n $namespace \
  --tty --stdin $efs_pod_name \
  -- cp /tmp/password-authenticator.properties /efs/password-authenticator.properties

kubectl exec -n $namespace \
  --tty --stdin $efs_pod_name \
  -- cp /tmp/tpcds.properties /efs/tpcds.properties

## Create password file

kubectl exec -n $namespace \
  --stdin --tty $efs_pod_name \
  -- touch /tmp/password.db

### Add additional kubectl exec for additional users, as necessary
kubectl exec -n $namespace \
  --stdin --tty $efs_pod_name \
  -- htpasswd -B -C 10 -b /tmp/password.db ${username1} ${password1} 

### Transfer password file to EFS
kubectl exec -n $namespace \
  --tty --stdin $efs_pod_name \
  -- cp /tmp/password.db /efs/password.db

# Get base64 of IAM user access and secret key
b64accesskey=$(echo ${accesskey} | base64)
b64secretkey=$(echo ${secretkey} | base64)

# Create secrets
cp k8s/create-secret-fargate.template.yaml temp/create-secret-fargate.yaml
sed -i "s/%namespace%/${namespace}/" temp/create-secret-fargate.yaml
sed -i "s/%username_base64%/${b64accesskey}/" temp/create-secret-fargate.yaml
sed -i "s/%password_base64%/${b64secretkey}/" temp/create-secret-fargate.yaml

kubectl apply -f temp/create-secret-fargate.yaml

# Get Fargate subnets

fargate_subnets_json=$(eksctl get fargateprofile  \
  --cluster ${clustername} -o json | jq '.[] | select(.name=="fp-warehouse")' | jq .subnets)

subnet_count=$(echo ${fargate_subnets_json} | jq length)
subnet_string=""

LOOPCOUNT=0

while [ "$LOOPCOUNT" -lt "$subnet_count"  ]
do
  subnet_string+=$(echo ${fargate_subnets_json} | jq .[$LOOPCOUNT] | sed 's/"//g')
  DIFF=$((subnet_count-LOOPCOUNT))
  if [ "$DIFF" -gt 1 ]; then
    subnet_string+=", "
  fi
  LOOPCOUNT=$((LOOPCOUNT+1))
done

echo "Fargate subnets: $subnet_string"

# Set up Presto deployment YAML script
cp k8s/presto-server-fargate.template.yaml temp/presto-server-fargate.yaml

CIDR_BLOCK=$(echo $CIDR_BLOCK | sed 's/\//\\\//g') # Add escape to CIDR Block

sed -i "s/%namespace%/${namespace}/g" temp/presto-server-fargate.yaml
sed -i "s/%region%/${region}/g" temp/presto-server-fargate.yaml
sed -i "s/%fargate_subnets%/$subnet_string/" temp/presto-server-fargate.yaml
sed -i "s/%alb_hostname%/$alb_hostname/" temp/presto-server-fargate.yaml
sed -i "s/%alb_certarn%/$alb_certarn/" temp/presto-server-fargate.yaml
sed -i "s/%CIDR_BLOCK%/$CIDR_BLOCK/" temp/presto-server-fargate.yaml
sed -i "s/%presto_image%/$presto_image/g" temp/presto-server-fargate.yaml

# Deploy Presto 
kubectl create -f temp/presto-server-fargate.yaml

# Checking Presto-coordinator deployment status

kubectl -n ${namespace} rollout status deployment presto-coordinator

# Check Presto-worker deployment status

kubectl -n ${namespace} rollout status deployment presto-worker

# Set HPA autoscaling to the worker nodes
kubectl -n $namespace autoscale deployment presto-worker `#The target average CPU utilization` \
    --cpu-percent=50 \
    --min=2 `#The lower limit for the number of pods that can be set by the autoscaler` \
    --max=10 `#The upper limit for the number of pods that can be set by the autoscaler`

# Check HPA
kubectl get hpa -n $namespace
