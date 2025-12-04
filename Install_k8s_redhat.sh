#!/bin/bash
#
# Kubernetes Installation Script for Red Hat Family Systems (RHEL/CentOS/Fedora)
# This script sets up the necessary kernel configuration, installs CRI-O as the
# container runtime, and installs the official Kubernetes components (kubeadm, kubelet, kubectl).
#
# NOTE: Run this script on ALL nodes (Control Plane and Worker Nodes).
# It must be run as root or using sudo.
#

# --- Configuration Variables ---
KUBE_VERSION="1.29.0" # Set your desired Kubernetes version (e.g., 1.29.x, 1.30.x)
CRIO_VERSION="1.29"  # CRI-O version should match the major/minor Kubernetes version

echo "Starting Kubernetes v${KUBE_VERSION} installation setup..."
echo "Container Runtime: CRI-O v${CRIO_VERSION}"

# ------------------------------
# 1. System Update and Dependencies
# ------------------------------

echo "--- 1. Updating System and Installing Dependencies ---"
sudo dnf update -y
sudo dnf install -y socat conntrack ipset vim git curl wget bash-completion

# ------------------------------
# 2. Configure SELinux and Firewall
# ------------------------------

echo "--- 2. Disabling SELinux and Firewalld ---"

# Disable SELinux permanently
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=disabled/' /etc/selinux/config
echo "SELinux has been disabled. Reboot is recommended but not mandatory for now."

# Stop and disable firewalld (or ensure necessary ports are open)
# For simplicity in testing/dev, we disable it. In production, open ports:
# Control Plane: 6443, 2379-2380, 10250, 10251, 10252, 10257, 10259
# Worker: 10250, 30000-32767
sudo systemctl stop firewalld
sudo systemctl disable firewalld

# ------------------------------
# 3. Configure Kernel Parameters (netfilter bridge Cgroup)
# ------------------------------

echo "--- 3. Configuring Kernel Parameters for Kubernetes ---"

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k9s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl parameters immediately
sudo sysctl --system

# Verify that br_netfilter module is loaded
if lsmod | grep -q br_netfilter; then
    echo "Kernel module br_netfilter loaded successfully."
else
    echo "ERROR: br_netfilter module failed to load. Check kernel headers."
    exit 1
fi

# ------------------------------
# 4. Install and Configure CRI-O (Container Runtime)
# ------------------------------

echo "--- 4. Installing CRI-O Container Runtime (v${CRIO_VERSION}) ---"

# Add CRI-O repository
# Detect RHEL/CentOS version (major release)
OS_RELEASE=$(grep -oP 'VERSION_ID="\K[^"]+' /etc/os-release | cut -d'.' -f1)
if [[ $OS_RELEASE -ge 9 ]]; then
    # RHEL 9 / CentOS Stream 9
    echo "Detected RHEL/CentOS 9 or newer."
    CRIO_REPO="https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/CentOS_9/devel:kubic:libcontainers:stable.repo"
    CRIO_KUBE_REPO="https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/${CRIO_VERSION}/CentOS_9/devel:kubic:libcontainers:stable:cri-o:${CRIO_VERSION}.repo"
else
    # RHEL 8 / CentOS Stream 8
    echo "Detected RHEL/CentOS 8."
    CRIO_REPO="https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/CentOS_8/devel:kubic:libcontainers:stable.repo"
    CRIO_KUBE_REPO="https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/${CRIO_VERSION}/CentOS_8/devel:kubic:libcontainers:stable:cri-o:${CRIO_VERSION}.repo"
fi

sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo ${CRIO_REPO}
sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable:cri-o:${CRIO_VERSION}.repo ${CRIO_KUBE_REPO}

# Install CRI-O
sudo dnf install -y cri-o

# Enable and start CRI-O
sudo systemctl daemon-reload
sudo systemctl enable crio --now
echo "CRI-O installed and started successfully."

# ------------------------------
# 5. Install Kubernetes Tools (kubeadm, kubelet, kubectl)
# ------------------------------

echo "--- 5. Installing Kubernetes Tools (kubeadm, kubelet, kubectl) ---"

# Add Kubernetes repository
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION%.*}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION%.*}/rpm/repodata/repomd.xml.key
EOF

# Ensure DNF can see the new repo
sudo dnf clean all

# Install Kubernetes packages and pin the version
sudo dnf install -y kubelet-"${KUBE_VERSION}" kubeadm-"${KUBE_VERSION}" kubectl-"${KUBE_VERSION}" --disableexcludes=kubernetes

# ------------------------------
# 6. Configure and Start Kubelet
# ------------------------------

echo "--- 6. Enabling and Starting Kubelet ---"

# Enable service and start it
sudo systemctl enable kubelet
sudo systemctl start kubelet

echo "Installation complete!"
echo "--------------------------------------------------------"
echo "NEXT STEPS:"
echo "--------------------------------------------------------"

# Provide next steps based on node type
if [[ $(hostname) == *"master"* ]] || [[ $(hostname) == *"control"* ]]; then
    echo "This script assumes this is a Control Plane node. Initialize the cluster:"
    echo "  sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=v${KUBE_VERSION}"
else
    echo "This script assumes this is a Worker node. Run the join command provided by the Control Plane initialization step."
fi

echo "To check the status of your services:"
echo "  sudo systemctl status crio"
echo "  sudo systemctl status kubelet"
echo "--------------------------------------------------------"

# Enable bash completion for kubectl
echo 'source <(kubectl completion bash)' >>~/.bashrc
echo 'alias k=kubectl' >>~/.bashrc
echo 'complete -F __start_kubectl k' >>~/.bashrc
source ~/.bashrc