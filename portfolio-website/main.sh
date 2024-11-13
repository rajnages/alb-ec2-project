#!/bin/bash

# Set strict error handling
# -e: Exit immediately if a command exits with non-zero status
# -u: Treat unset variables as an error
# -o pipefail: Return value of a pipeline is the value of the last (rightmost) command to exit with non-zero status
# IFS: Internal Field Separator set to newline and tab for safer word splitting
set -euo pipefail
IFS=$'\n\t'

# Global variables
KUBECTL_VERSION="1.27.4"
KUBECTL_DATE="2023-08-16"
#FLASK_REPO="https://github.com/joozero/amazon-eks-flask.git"
ECR_REPO_NAME="portfolio-website"

# Logging functions
# These functions provide formatted log output with different colors and labels:
# - log_info: Green text for general information messages
# - log_error: Red text for error messages, outputs to stderr
# - log_warning: Yellow text for warning messages
log_info() {
    echo -e "\033[0;32m[INFO]\033[0m $1"
}

log_error() {
    # This line prints an error message in red text to stderr
    # \033[0;31m - Sets text color to red
    # [ERROR] - The error label
    # \033[0m - Resets text color back to default
    # $1 - The error message passed as an argument
    # >&2 - Redirects output to stderr instead of stdout
    echo -e "\033[0;31m[ERROR]\033[0m $1" >&2
}

log_warning() {
    echo -e "\033[0;33m[WARNING]\033[0m $1"
}

# Check if a command exists in the system PATH
# $1: The command name to check
# Returns: 0 if command exists, 1 if it doesn't
command_exists() {
    # Use command -v to check if command exists
    # -v: Print command path or return error if not found
    # >/dev/null: Suppress stdout
    # 2>&1: Redirect stderr to stdout
    command -v "$1" >/dev/null 2>&1
}

# Error handling
# This section sets up error handling for the script:
# - handle_error(): Function that logs the line number where an error occurred and exits
# - trap: Sets up a trap to catch any errors and call handle_error with the line number
handle_error() {
    # $1 contains the line number passed from $LINENO
    # Log the error and exit with status 1 to indicate failure
    log_error "An error occurred on line $1" 
    exit 1
}

# Set up trap to catch errors
# ERR is triggered when any command returns non-zero
# $LINENO provides the current line number where the error occurred
trap 'handle_error $LINENO' ERR

# Install dependencies
install_dependencies() {
    log_info "Installing system dependencies..."
    sudo apt update
    sudo apt install -y unzip jq bash-completion python3-pip curl
}

# Install AWS CLI
install_awscli() {
    if ! command_exists aws; then
        log_info "Installing AWS CLI..."
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip -q awscliv2.zip
        sudo ./aws/install
        rm -rf aws awscliv2.zip
        log_info "AWS CLI installed successfully: $(aws --version)"
    else
        log_info "AWS CLI already installed: $(aws --version)"
    fi
}

# Install kubectl
install_kubectl() {
    if ! command_exists kubectl; then
        log_info "Installing kubectl..."
        sudo curl -sSL -o /usr/local/bin/kubectl \
            "https://s3.us-west-2.amazonaws.com/amazon-eks/${KUBECTL_VERSION}/${KUBECTL_DATE}/bin/linux/amd64/kubectl"
        sudo chmod +x /usr/local/bin/kubectl
        log_info "kubectl installed successfully: $(kubectl version --client=true --short=true)"
    else
        log_info "kubectl already installed: $(kubectl version --client=true --short=true)"
    fi
}

# Install eksctl
install_eksctl() {
    if ! command_exists eksctl; then
        log_info "Installing eksctl..."
        curl -sSL "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | \
            sudo tar xz -C /usr/local/bin
        log_info "eksctl installed successfully: $(eksctl version)"
    else
        log_info "eksctl already installed: $(eksctl version)"
    fi
}

# Configure AWS environment
configure_aws() {
    log_info "Configuring AWS environment..."
    
    # Get instance metadata token
    TOKEN=$(curl -sSL -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    
    # Set AWS region
    export AWS_REGION=$(curl -sSL -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')
    
    # Set AWS account ID
    export ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
    
    # Update environment files
    {
        echo "export AWS_REGION=${AWS_REGION}"
        echo "export ACCOUNT_ID=${ACCOUNT_ID}"
    } >> ~/.bash_profile
    
    aws configure set default.region "${AWS_REGION}"
}

# Setup Docker environment
setup_docker() {
    log_info "Setting up Docker environment..."
    if ! command_exists docker; then
        sudo curl -sSL https://get.docker.com | sudo bash
        sudo usermod -aG docker ubuntu
        log_info "Docker installed successfully"
    fi
    
    # Clone portfolio website repository
    git clone https://github.com/rajnages/alb-ec2-project.git
    cd alb-ec2-project/portfolio-website
    # Build docker image
    docker build -t portfolio-website .
    docker run -d -p 8080:80 --name portfolio-website portfolio-website
}

# Setup ECR and push images
setup_ecr() {
    log_info "Setting up ECR repository..."
    
    # Create ECR repository if it doesn't exist
    if ! aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" 2>/dev/null; then
        aws ecr create-repository \
            --repository-name "${ECR_REPO_NAME}" \
            --image-scanning-configuration scanOnPush=true \
            --region "${AWS_REGION}"
    fi
    
    # Login to ECR
    aws ecr get-login-password --region "${AWS_REGION}" | \
        docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    
    # Clone and build Flask application
    if [ ! -d "alb-ec2-project" ]; then
        git clone https://github.com/rajnages/alb-ec2-project.git
    fi
    
    cd alb-ec2-project/portfolio-website
    docker build -t "${ECR_REPO_NAME}" .
    docker tag "${ECR_REPO_NAME}:latest" "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}:latest"
    docker push "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}:latest"
}

# Create EKS cluster
create_eks_cluster() {
    log_info "Creating EKS cluster..."
    
    # Create cluster without nodegroup
    eksctl create cluster \
        --name=eksdemo \
        --region="${AWS_REGION}" \
        --zones="${AWS_REGION}a,${AWS_REGION}b" \
        --without-nodegroup
    
    # Associate IAM OIDC provider
    eksctl utils associate-iam-oidc-provider \
        --region "${AWS_REGION}" \
        --cluster eksdemo \
        --approve
    
    # Create nodegroup
    eksctl create nodegroup \
        --cluster=eksdemo \
        --region="${AWS_REGION}" \
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
}

# Verify cluster status
verify_cluster() {
    log_info "Verifying cluster status..."
    eksctl get cluster
    eksctl get nodegroup --cluster eksdemo
    kubectl get nodes
}

# Main execution
main() {
    log_info "Starting installation process..."
    
    install_dependencies
    install_awscli
    install_kubectl
    install_eksctl
    configure_aws
    setup_docker
    setup_ecr
    create_eks_cluster
    verify_cluster
    
    log_info "Installation completed successfully!"
}

# Execute main function
main