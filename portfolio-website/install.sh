#! /bin/bash

# Install AWS CLI
sudo apt update
echo "Installing AWS CLI..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo apt install unzip -y
unzip awscliv2.zip
sudo ./aws/install
aws --version

# Install kubectl
sudo apt update
echo "Installing kubectl..."
sudo curl -o /usr/local/bin/kubectl \
   https://s3.us-west-2.amazonaws.com/amazon-eks/1.27.4/2023-08-16/bin/linux/amd64/kubectl
sudo chmod +x /usr/local/bin/kubectl
kubectl version --client=true --short=true

# Install additional tools
sudo apt update
echo "Installing additional tools..."
sudo apt install jq bash-completion -y
python3 --version
curl -O https://bootstrap.pypa.io/get-pip.py
python3 get-pip.py --user
pip3 --version

# Install eksctl
sudo apt update
echo "Installing eksctl..."
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv -v /tmp/eksctl /usr/local/bin
eksctl version

# Configure AWS region
sudo apt update
echo "Configuring AWS region..."
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
export AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')
echo "export AWS_REGION=${AWS_REGION}" >> ~/.bash_profile
aws configure set default.region ${AWS_REGION}
aws configure get default.region

# Set default AWS account
sudo apt update
echo "Setting default AWS account..."
export ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
echo "export ACCOUNT_ID=${ACCOUNT_ID}" >> ~/.bash_profile

# Resolve disk space
# sudo apt update
# echo "Resolving disk space..."
# wget https://gist.githubusercontent.com/joozero/b48ee68e2174a4f1ead93aaf2b582090/raw/2dda79390a10328df66e5f6162846017c682bef5/resize.sh
# bash resize.sh
# df -h

# Build and test Docker image
sudo apt update
echo "Building and testing Docker image..."
cat << EOF > Dockerfile
FROM nginx:latest
RUN  echo '<h1> test nginx web page </h1>'  >> index.html
RUN cp /index.html /usr/share/nginx/html
EOF
sudo curl https://get.docker.com | sudo bash
sudo usermod -aG docker ubuntu
docker build -t test-image .
docker images
docker run -d -p 8080:80 --name test-nginx test-image
# docker ps
# docker logs test-nginx
# docker exec -it test-nginx /bin/bash
# docker stop test-nginx
# docker rm test-nginx

# Setup ECR and push image
sudo apt update
echo "Setting up ECR and pushing image..."
git clone https://github.com/joozero/amazon-eks-flask.git
cd amazon-eks-flask
aws ecr create-repository \
    --repository-name demo-flask-backend \
    --image-scanning-configuration scanOnPush=true \
    --region ${AWS_REGION}

aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

cd ~/environment/amazon-eks-flask
docker build -t demo-flask-backend .
docker tag demo-flask-backend:latest $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/demo-flask-backend:latest
docker push $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/demo-flask-backend:latest

# Create EKS cluster
sudo apt update
echo "Creating EKS cluster..."
# Option 1: Using eksctl command
# eksctl create cluster --name=eksdemo1 \
#     --region=us-east-1 \
#     --zones=us-east-1a,us-east-1b \
#     --node-type=t3.medium \
#     --nodes=2 \
#     --nodes-min=2 \
#     --nodes-max=4 \
#     --node-volume-size=20 \
#     --ssh-access \
#     --ssh-public-key=eks-cluster-key \
#     --managed \
#     --asg-access \
#     --external-dns-access \
#     --full-ecr-access \
#     --appmesh-access \
#     --alb-ingress-access \
#     --with-oidc

# echo "requered permission to create cluster"
# # Attach role to Cloud9 EC2 instance
# aws iam attach-role-policy \
#     --role-name cloud9-role \
#     --policy-arn arn:aws:iam::aws:policy/AWSCloudFormationFullAccess

# # Also attach EKS required policies
# aws iam attach-role-policy \
#     --role-name cloud9-role \
#     --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy


## In Cloud9 preferences:
#1. Go to AWS Settings
#2. Ensure "AWS managed temporary credentials" is enabled

echo "Creating EKS cluster without nodegroup..."
eksctl create cluster --name=eksdemo \
                      --region=us-east-1 \
                      --zones=us-east-1a,us-east-1b \
                      --without-nodegroup 

echo "Associating IAM OIDC provider..."
eksctl utils associate-iam-oidc-provider \
    --region us-east-1 \
    --cluster eksdemo \
    --approve


echo "Creating nodegroup..."
eksctl create nodegroup --cluster=eksdemo \
                       --region=us-east-1 \
                       --name=eksdemo-ng-public1 \
                       --node-type=t3.medium \
                       --nodes=2 \
                       --nodes-min=2 \
                       --nodes-max=4 \
                       --node-volume-size=20 \
                       --ssh-access \
                       --ssh-public-key=eks-cluster-key \
                       --managed \
                       --asg-access \
                       --external-dns-access \
                       --full-ecr-access \
                       --appmesh-access \
                       --alb-ingress-access 
#aws eks update-kubeconfig --name eksdemo --region us-east-1  
##arn:aws:sts::471112609691:assumed-role/eks-cluster-role/i-0e27561c756dadbfe     
# Option 2: Using config file
# eksctl create cluster -f eks-demo-cluster.yaml

# Check cluster status
echo "Checking cluster status..."
eksctl get cluster
eksctl get nodegroup --cluster my-cluster
kubectl get nodes

# # Delete cluster
# echo "Deleting cluster..."
# eksctl delete cluster --name eksdemo1 --region us-east-1

# #delete or checking cloud formation stack
# # List all CloudFormation stacks
# aws cloudformation list-stacks --region us-east-1
# # Delete specific stack
# aws cloudformation delete-stack --stack-name eksctl-demo-cluster-cluster --region us-east-1
# # Delete nodegroup stack (if exists)
# aws cloudformation delete-stack --stack-name eksctl-demo-cluster-nodegroup-my-nodes --region us-east-1

#https://oidc.eks.us-east-1.amazonaws.com/id/417C15765AEA5139A3BDCEE53BD6C04E
#aws iam list-open-id-connect-providers | grep 417C15765AEA5139A3BDCEE53BD6C04E





                     