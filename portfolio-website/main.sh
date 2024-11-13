#!/bin/bash

# This script automates the setup of a Kubernetes cluster on AWS EKS with a portfolio website deployment
# It handles installation of required tools, AWS configuration, Docker setup, and EKS cluster creation

# Enable strict error handling to catch failures early
set -euo pipefail
IFS=$'\n\t'

# Define key configuration values as constants
readonly KUBECTL_VERSION="1.27.4"  # Version of kubectl to install
readonly KUBECTL_DATE="2023-08-16" # Release date of kubectl version
readonly ECR_REPO_NAME="portfolio-website"  # Name for the ECR repository
readonly CLUSTER_NAME="portfolio-cluster"   # Name for the EKS cluster
readonly NODE_GROUP_NAME="portfolio-ng"     # Name for the EKS node group

# Utility functions for consistent log output formatting
log_info() {
    echo -e "\033[0;32m[INFO]\033[0m $1"    # Green text for info messages
}

log_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1" >&2  # Red text for error messages
}

log_warning() {
    echo -e "\033[0;33m[WARNING]\033[0m $1"    # Yellow text for warnings
}

# Helper function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Error handler that shows which line caused the error
handle_error() {
    log_error "An error occurred on line $1"
    exit 1
}

# Set up error trap to catch failures
trap 'handle_error $LINENO' ERR

# Install required system packages
install_dependencies() {
    log_info "Installing system dependencies..."
    if ! sudo apt update &>/dev/null; then
        log_error "Failed to update package lists"
        exit 1
    fi
    
    # Install essential tools needed for the setup
    local deps=(unzip jq bash-completion python3-pip curl)
    if ! sudo apt install -y "${deps[@]}" &>/dev/null; then
        log_error "Failed to install dependencies"
        exit 1
    fi
    log_info "Dependencies installed successfully"
}

# Install AWS CLI if not already present
install_awscli() {
    if ! command_exists aws; then
        log_info "Installing AWS CLI..."
        local temp_dir=$(mktemp -d)
        pushd "$temp_dir" &>/dev/null
        
        # Download and install AWS CLI
        curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip -q awscliv2.zip
        sudo ./aws/install
        
        popd &>/dev/null
        rm -rf "$temp_dir"
        
        if ! command_exists aws; then
            log_error "AWS CLI installation failed"
            exit 1
        fi
        log_info "AWS CLI installed successfully: $(aws --version)"
    else
        log_info "AWS CLI already installed: $(aws --version)"
    fi
}

# Install kubectl for managing Kubernetes cluster
install_kubectl() {
    if ! command_exists kubectl; then
        log_info "Installing kubectl..."
        local kubectl_url="https://s3.us-west-2.amazonaws.com/amazon-eks/${KUBECTL_VERSION}/${KUBECTL_DATE}/bin/linux/amd64/kubectl"
        if ! sudo curl -sSL -o /usr/local/bin/kubectl "$kubectl_url"; then
            log_error "Failed to download kubectl"
            exit 1
        fi
        sudo chmod +x /usr/local/bin/kubectl
        log_info "kubectl installed successfully: $(kubectl version --client=true --short=true)"
    else
        log_info "kubectl already installed: $(kubectl version --client=true --short=true)"
    fi
}

# Install eksctl for creating and managing EKS clusters
install_eksctl() {
    if ! command_exists eksctl; then
        log_info "Installing eksctl..."
        local eksctl_url="https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz"
        if ! curl -sSL "$eksctl_url" | sudo tar xz -C /usr/local/bin; then
            log_error "Failed to install eksctl"
            exit 1
        fi
        log_info "eksctl installed successfully: $(eksctl version)"
    else
        log_info "eksctl already installed: $(eksctl version)"
    fi
}

# Configure AWS environment with instance metadata
configure_aws() {
    log_info "Configuring AWS environment..."
    
    # Get instance metadata token with retry mechanism
    local retries=3
    local TOKEN=""
    while [[ $retries -gt 0 ]]; do
        TOKEN=$(curl -sSL -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") && break
        retries=$((retries-1))
        sleep 2
    done
    
    if [[ -z "$TOKEN" ]]; then
        log_error "Failed to retrieve metadata token"
        exit 1
    fi
    
    # Get and export AWS region and account ID
    export AWS_REGION=$(curl -sSL -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')
    export ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
    
    # Save environment variables permanently
    cat >> ~/.bash_profile <<EOF
export AWS_REGION=${AWS_REGION}
export ACCOUNT_ID=${ACCOUNT_ID}
EOF
    
    aws configure set default.region "${AWS_REGION}"
}

# Set up Docker and build/run the portfolio website
setup_docker() {
    log_info "Setting up Docker environment..."
    if ! command_exists docker; then
        if ! curl -sSL https://get.docker.com | sudo bash; then
            log_error "Docker installation failed"
            exit 1
        fi
        sudo usermod -aG docker "$USER"
        log_info "Docker installed successfully"
        # Reload user groups without logout
        exec sudo su -l "$USER"
    fi
    
    # Clone and build the portfolio website
    if [ ! -d "alb-ec2-project" ]; then
        git clone https://github.com/rajnages/alb-ec2-project.git
    fi
    
    cd alb-ec2-project/portfolio-website || exit 1
    docker build -t portfolio-website .
    docker run -d -p 8080:80 --name portfolio-website --restart unless-stopped portfolio-website
}

# Set up Amazon ECR repository and push Docker image
setup_ecr() {
    log_info "Setting up ECR repository..."
    
    # Create ECR repository if needed
    if ! aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" &>/dev/null; then
        aws ecr create-repository \
            --repository-name "${ECR_REPO_NAME}" \
            --image-scanning-configuration scanOnPush=true \
            --region "${AWS_REGION}"
    fi
    
    # Login to ECR with retries
    local retries=3
    while [[ $retries -gt 0 ]]; do
        if aws ecr get-login-password --region "${AWS_REGION}" | \
            docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"; then
            break
        fi
        retries=$((retries-1))
        sleep 2
    done
    
    if [[ $retries -eq 0 ]]; then
        log_error "Failed to login to ECR"
        exit 1
    fi
    
    # Build and push Docker image to ECR
    cd alb-ec2-project/portfolio-website || exit 1
    docker build -t "${ECR_REPO_NAME}" .
    docker tag "${ECR_REPO_NAME}:latest" "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}:latest"
    docker push "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}:latest"
}

# Create EKS cluster and node group
create_eks_cluster() {
    log_info "Creating EKS cluster..."
    
    # Create cluster with retry logic
    local retries=3
    while [[ $retries -gt 0 ]]; do
        if eksctl create cluster \
            --name="${CLUSTER_NAME}" \
            --region="${AWS_REGION}" \
            --zones="${AWS_REGION}a,${AWS_REGION}b" \
            --without-nodegroup; then
            break
        fi
        retries=$((retries-1))
        sleep 5
    done
    
    if [[ $retries -eq 0 ]]; then
        log_error "Failed to create EKS cluster"
        exit 1
    fi
    
    # Set up IAM OIDC provider for cluster
    eksctl utils associate-iam-oidc-provider \
        --region "${AWS_REGION}" \
        --cluster "${CLUSTER_NAME}" \
        --approve
    
    # Create node group with specified configuration
    eksctl create nodegroup \
        --cluster="${CLUSTER_NAME}" \
        --region="${AWS_REGION}" \
        --name="${NODE_GROUP_NAME}" \
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

# Verify cluster is running correctly
verify_cluster() {
    log_info "Verifying cluster status..."
    local retries=5
    
    while [[ $retries -gt 0 ]]; do
        if eksctl get cluster | grep -q "${CLUSTER_NAME}" && \
           eksctl get nodegroup --cluster "${CLUSTER_NAME}" | grep -q "ACTIVE" && \
           kubectl get nodes | grep -q "Ready"; then
            log_info "Cluster verification successful"
            return 0
        fi
        retries=$((retries-1))
        sleep 10
    done
    
    log_error "Cluster verification failed"
    exit 1
}

# Cleanup function for graceful shutdown
cleanup() {
    log_info "Performing cleanup..."
    # Add cleanup tasks here if needed
}

# Main function that orchestrates the entire setup
main() {
    log_info "Starting installation process..."
    
    # Register cleanup handler
    trap cleanup EXIT
    
    # Execute all setup steps in sequence
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

# Start the script by calling main
main