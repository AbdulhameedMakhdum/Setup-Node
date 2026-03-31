#!/bin/bash

# Simple Compute Node Setup Script (runs ON the compute node)
# Based on the suggested script structure from requirements
# Usage: ./setup_compute_node.sh <node_name> <headnode_ip> [headnode_password]

# Check arguments
if [ $# -ne 3 ]; then
    echo "Error: Exactly 3 arguments required"
    echo "Usage: $0 <node_name> <headnode_ip> <headnode_password>"
    echo "Example: $0 node01 192.168.56.100 mypassword"
    exit 1
fi

NODE_NAME=$1
HEADNODE_IP=$2
HEADNODE_PASSWORD=$3

# Check if node name starts with a letter
if [[ ! $NODE_NAME =~ ^[a-zA-Z] ]]; then
    echo "Error: Node name must start with a letter"
    echo "Usage: $0 <node_name> <headnode_ip> <headnode_password>"
    echo "Example: $0 node01 192.168.56.100 mypassword"
    exit 1
fi

# Check if IP address format is valid
if [[ ! $HEADNODE_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Error: Invalid IP address format"
    echo "Usage: $0 <node_name> <headnode_ip> <headnode_password>"
    echo "Example: $0 node01 192.168.56.100 mypassword"
    exit 1
fi

# Get this node's IP automatically
NODE_IP=$(hostname -I | awk '{print $1}')

echo "Setting up compute node: $NODE_NAME with IP: $NODE_IP"
echo "Head node IP: $HEADNODE_IP"

# 1. Ensure the new compute virtual machines (VMs) are already created and booted
# 1a. Setup local repository from DVD/CDROM
echo "Setting up local repository..."
mkdir -p /cdrom
mount /dev/sr0 /cdrom

# 1b. Configure CentOS-Media.repo using sed
echo "Configuring CentOS-Media.repo..."
sed -i 's|baseurl=file:///media/CentOS/|baseurl=file:///cdrom|g' /etc/yum.repos.d/CentOS-Media.repo
sed -i '/file:\/\/\/media\/cdrom\//d' /etc/yum.repos.d/CentOS-Media.repo
sed -i '/file:\/\/\/media\/cdrecorder\//d' /etc/yum.repos.d/CentOS-Media.repo
sed -i 's/enabled=0/enabled=1/g' /etc/yum.repos.d/CentOS-Media.repo

# 1c. Enable all repositories in CentOS-Base.repo
echo "Configuring CentOS-Base.repo..."
sed -i '/gpgcheck=1/a enabled=0' /etc/yum.repos.d/CentOS-Base.repo

# 1d. Install expect first
echo "Installing expect..."
yum install -y expect >/dev/null 2>&1

# 2. Log in to each new VM and run the following steps to configure it as a compute node
# (No code required - manual login to VM)

# 3. Set the hostname to a unique name (e.g., node02, node03)
echo "Setting hostname..."
hostnamectl set-hostname $NODE_NAME

# 4. Update the /etc/hosts file to include the head node and both compute nodes' IP addresses
echo "Updating /etc/hosts..."
expect << EOF
spawn scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$HEADNODE_IP:/etc/hosts /tmp/headnode_hosts
expect "password:" { send "$HEADNODE_PASSWORD\r" }
expect eof
EOF

echo "$NODE_IP $NODE_NAME" >> /tmp/headnode_hosts
cp /tmp/headnode_hosts /etc/hosts

expect << EOF
spawn scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/headnode_hosts root@$HEADNODE_IP:/etc/hosts
expect "password:" { send "$HEADNODE_PASSWORD\r" }
expect eof
EOF

# 5. Generate or copy an SSH public key from the head node and place it in the compute node's ~/.ssh/authorized_keys file for passwordless login
echo "Setting up bidirectional SSH for passwordless access..."
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

if [ -n "$HEADNODE_PASSWORD" ]; then
    echo "Setting up SSH keys automatically..."
    
    # 5a. Generate SSH key on compute node if needed
    test -f ~/.ssh/id_rsa || ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa
    
    # 5b. Generate SSH key on headnode if needed and get public key
    expect << EOF
set timeout 30
log_user 0

# First, generate SSH key on headnode if needed
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$HEADNODE_IP "test -f ~/.ssh/id_rsa || ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa"
expect "password:" { send "$HEADNODE_PASSWORD\r" }
expect eof

# Get the headnode's public key
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$HEADNODE_IP "cat ~/.ssh/id_rsa.pub"
expect "password:" { send "$HEADNODE_PASSWORD\r" }
expect eof
EOF

    # 5c. Extract headnode's public key and add to authorized_keys
    PUBLIC_KEY=$(expect << EOF
set timeout 30
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$HEADNODE_IP "cat ~/.ssh/id_rsa.pub"
expect "password:" { send "$HEADNODE_PASSWORD\r" }
expect eof
EOF
)
    
    # 5d. Add headnode's key to compute node
    if echo "$PUBLIC_KEY" | grep -q "ssh-rsa"; then
        echo "$PUBLIC_KEY" | grep "ssh-rsa" >> ~/.ssh/authorized_keys
        echo "✓ Headnode SSH key added to compute node"
    else
        echo "✗ Failed to get headnode SSH key"
    fi
    
    # 5e. Add compute node's key to headnode
    echo "Setting up reverse SSH access (compute node → headnode)..."
    expect << EOF
spawn ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$HEADNODE_IP
expect "password:" { send "$HEADNODE_PASSWORD\r" }
expect eof
EOF
    echo "✓ Compute node SSH key added to headnode"
    
    # 5f. Create user1 on compute node and set up SSH
    echo "Creating user1 and setting up SSH..."
    useradd -m user1
    echo "user1:123" | chpasswd
    
    # 5g. Set up SSH for user1
    sudo -u user1 mkdir -p /home/user1/.ssh
    sudo -u user1 chmod 700 /home/user1/.ssh
    sudo -u user1 ssh-keygen -t rsa -N '' -f /home/user1/.ssh/id_rsa
    
    # 5h. Copy user1's SSH key to headnode (assuming user1 exists on headnode)
    echo "Setting up user1 SSH access to headnode..."
    expect << EOF
spawn sudo -u user1 ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null user1@$HEADNODE_IP
expect "password:" { send "123\r" }
expect eof
EOF
    
    # 5i. Set up reverse SSH (headnode user1 → compute node user1)
    echo "Setting up reverse SSH access for user1..."
    
    # Generate SSH key for user1 on headnode
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$HEADNODE_IP "sudo -u user1 ssh-keygen -t rsa -N '' -f /home/user1/.ssh/id_rsa 2>/dev/null || true"
    
    # Get headnode user1's public key and add to compute node
    HEADNODE_USER1_KEY=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$HEADNODE_IP "sudo -u user1 cat /home/user1/.ssh/id_rsa.pub")
    echo "$HEADNODE_USER1_KEY" >> /home/user1/.ssh/authorized_keys
    
    echo "✓ user1 created with password '123' and bidirectional SSH configured"
    
else
    echo "No password provided. Manual SSH setup required."
fi

# 6. Install NFS utilities and mount the shared directory (e.g., /ddn) from the head node. Ensure the mount is persistent by updating /etc/fstab
echo "Installing NFS utilities..."
yum install -y nfs-utils
systemctl stop firewalld
systemctl disable firewalld
service nfs restart

# 6a. Create shared directory
echo "Creating /ddn directory..."
mkdir -p /ddn

# 6b. Add NFS mount to /etc/fstab for persistence
echo "Adding NFS mount to /etc/fstab..."
echo "$HEADNODE_IP:/ddn /ddn nfs defaults 0 0" >> /etc/fstab

# 6c. Mount NFS share
echo "Mounting NFS share..."
mount -a

# 7. Install the PBS MOM package (e.g., pbspro-execution) using your package manager (e.g., yum)
echo "Configuring PBS..."

# 7a. Disable SELinux
echo "Disabling SELinux..."
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
sed -i 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config

# 7b. Change to PBS directory and install
echo "Installing PBS execution daemon..."
cd /pbspro_19.1.3.centos_7
yum install -y pbspro-execution-19.1.3-0.x86_64.rpm

# 7c. Install environment modules
echo "Installing environment modules..."
yum install environment-modules -y

# 7d. Configure PBS server
echo "Configuring PBS server..."
sed -i 's/PBS_SERVER=.*/PBS_SERVER=headnode/g' /etc/pbs.conf

# 8. Configure PBS by adding the head node's hostname into the MOM configuration file: /var/spool/pbs/mom_priv/config
echo "Configuring PBS client..."
echo '$clienthost headnode' > /var/spool/pbs/mom_priv/config

# 9. Enable and start the PBS service using systemctl: systemctl enable pbs && systemctl start pbs
echo "Starting PBS services..."
/etc/init.d/pbs start
/opt/pbs/libexec/pbs_postinstall
/etc/init.d/pbs start
service pbs restart

# 10. Verify that the node has been added to the PBS system by running pbsnodes on the head node
echo "Registering node with PBS on headnode..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$HEADNODE_IP "qmgr -c 'create node $NODE_NAME'"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$HEADNODE_IP "qmgr -c 'set node $NODE_NAME queue=hpcc'"

echo "Compute node setup completed!"
echo "Node: $NODE_NAME ($NODE_IP) is ready"

# 11. Repeat these steps for the second compute node using a different IP and hostname
# (No code required - manually run this script again with different parameters)
