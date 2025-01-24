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

# Initialize Kubernetes master
kubeadm init --pod-network-cidr=10.244.0.0/16

# Configure kubectl for admin
mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Apply a CNI plugin (Flannel)
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

# Generate the join command and store it
kubeadm token create --print-join-command > /opt/join-command.sh
chmod 600 /opt/join-command.sh

# Fetch master IP dynamically using AWS EC2 API
ROLE_TAG="K8sMaster"
AWS_REGION="${AWS_REGION}"

PRIVATE_IP=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:Role,Values=$ROLE_TAG" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[0].PrivateIpAddress" \
  --output text)

if [ -z "$PRIVATE_IP" ]; then
  echo "Error: Unable to find the master node. Exiting."
  exit 1
fi

# Store the join command and private IP in SSM Parameter Store
aws ssm put-parameter --name "/k8s/join-command" --type "String" --value "$(cat /opt/join-command.sh)" --overwrite --region "$AWS_REGION"
aws ssm put-parameter --name "/k8s/master-private-ip" --type "String" --value "$PRIVATE_IP" --overwrite --region "$AWS_REGION"

echo "Kubernetes master setup is complete. Join command and private IP have been stored in SSM Parameter Store."
