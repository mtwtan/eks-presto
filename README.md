# Deploying Serverless Presto on Amazon EKS Fargate

## Introduction
This sample code here helps you deploy Presto as a serverless analytic service. The following components will be required:

1. TrinoDB Docker container image
2. An Amazon EKS cluster
3. Glue catalog
4. S3 bucket 
5. EFS File system
6. EC2 Application Load Balancer
7. SSL/TLS cert on Certificate Manager
8. Route53 or another DNS system
9. Amazon ECR or another suitable Docker registry
10. Docker installed on the Cloud9 desktop or in another desktop to build the container images to be pushed into the registry

To run this sample code, the dependencies are as follows:

- Deploy the code using AWS Cloud9 Desktop
- Set up the Cloud9 Desktop according to the [EKS Workshop pre-requisites](https://www.eksworkshop.com/020_prerequisites/workspace/)
- Install [Kubernetes tools](https://www.eksworkshop.com/020_prerequisites/k8stools/)
- Install [eksctl](https://www.eksworkshop.com/030_eksctl/prerequisites/) 
- The IAM role attached to the desktop has to have AdministratorAccess policy 

## Downloading the code
```
$ git clone https://github.com/mtwtan/eks-presto.git
```
## Creating the Docker container images

There are two Docker images. The first one is a small pod used to inject the Presto configuration files into the EFS file system. The second image is the TrinoDB container.
```
$ cd <ROOT>/eks-presto/docker

# Build the EFS pod image
$ docker build -t example/presto-efs:1.0 -f Dockerfile-efs .

# Build the TrinoDB image
$ docker build -t example/presto-server:1.0 -f Dockerfile-presto-server .
```

Tag and push the images into the container registry

## Deploy the code

### Fill out the parameters in parameters.sh
See the parameters.sh example and description and fill them out accordingly

### Start the installation process

```
$ cd <ROOT>/eks-presto
$ bash env.sh <account ID> <IAM user access key> <IAM user secret key>
```

### Pod Autoscaler
To scale the workload use HPA to scale the pods by:
```
kubectl autoscale deployment presto-worker `#The target average CPU utilization` \
    --cpu-percent=50 \
    --min=2 `#The lower limit for the number of pods that can be set by the autoscaler` \
    --max=10 `#The upper limit for the number of pods that can be set by the autoscaler`
```

## Post-Launch and Screenshots
### Take the DNS provided by the Application Load Balancer and add it to the CNAME value of your chosen domain name.

### Go to https://YourDomainName:8443/ui/login.html

<img src="https://github.com/mtwtan/eks-presto/-/raw/master/images/presto-login.png?inline=false" width="800px" />

### Login with the username and password that was entered in the parameters.sh. Upon successful login, you can see the Presto UI dashboard:

<img src="https://github.com/mtwtan/eks-presto/-/raw/master/images/presto-ui.png?inline=false" width="800px" />

### Set up a JDBC connection from an SQL JDBC client:

<img src="https://github.com/mtwtan/eks-presto/-/raw/master/images/jdbc_connection.png?inline=false" width="800px" />

### Make sure that the driver properties are added with the appropriate SSL Truststore information:
<img src="https://github.com/mtwtan/eks-presto/-/raw/master/images/jdbc_driver_properties.png?inline=false" width="800px" />

### See the tables in the catalog and run a simple SQL script:
<img src="https://github.com/mtwtan/eks-presto/-/raw/master/images/view_from_sql_bench.png?inline=false" width="800px" />

### View the load on the Presto cluster in the UI Dashboard:
<img src="https://github.com/mtwtan/eks-presto/-/raw/master/images/presto-ui-status.png?inline=false" width="800px" />