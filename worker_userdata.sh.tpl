#!/bin/bash
set -e

# Update and install dependencies
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gpg unzip jq gnupg2 software-properties-common

# Install AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y

# Install Docker and its plugins
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start and enable Docker service
systemctl start docker
systemctl enable docker

# Install Kubernetes tools
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

rm /etc/containerd/config.toml
systemctl restart containerd

# Define AWS_REGION and ROLE_TAG
AWS_REGION="${AWS_REGION}" # Default to us-east-1 if AWS_REGION is not set
ROLE_TAG="K8sMaster"

# Fetch master IP dynamically using AWS EC2 API
MASTER_IP=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:Role,Values=$ROLE_TAG" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[0].PrivateIpAddress" \
  --output text)

if [ -z "$MASTER_IP" ]; then
  echo "Error: Unable to find the master node. Exiting."
  exit 1
fi

# Retrieve the private key from SSM (ensure directory exists and permissions are correct)
mkdir -p /home/ubuntu/.ssh
aws ssm get-parameter --name "/k8s/id_rsa_k8s" --region "$AWS_REGION" --with-decryption --query "Parameter.Value" --output text > /home/ubuntu/.ssh/id_rsa_k8s
chmod 600 /home/ubuntu/.ssh/id_rsa_k8s
chown ubuntu:ubuntu /home/ubuntu/.ssh/id_rsa_k8s

# Retrieve the join command from SSM
aws ssm get-parameter --name "/k8s/join-command" --region "$AWS_REGION" --with-decryption --query "Parameter.Value" --output text > /home/ubuntu/join-command.sh
chmod +x /home/ubuntu/join-command.sh
chown ubuntu:ubuntu /home/ubuntu/join-command.sh

# Optionally, you can directly execute the join command
/home/ubuntu/join-command.sh

echo "Kubernetes worker node setup is complete."
