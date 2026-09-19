# VPC and Networking
resource "aws_vpc" "capstone_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "capstone-vpc" }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.capstone_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = var.availability_zone

  tags = { Name = "capstone-public-subnet" }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.capstone_vpc.id

  tags = { Name = "capstone-igw" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.capstone_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = { Name = "capstone-public-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# Key Pair
resource "aws_key_pair" "deployer" {
  key_name   = "capstone-key"
  public_key = file(var.ssh_public_key_path)
}

# Security Group
resource "aws_security_group" "k3s_sg" {
  name        = "k3s-capstone-sg"
  description = "Security group for multi-node K3s cluster"
  vpc_id      = aws_vpc.capstone_vpc.id

  ingress {
    description = "SSH - admin only, not the whole internet"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "K3s API Server - admin only, not the whole internet"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "HTTP Traffic"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS Traffic"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow internal node-to-node communication"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "k3s-capstone-sg" }
}

# Ubuntu 22.04 AMI Data Source
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# 1x Control Plane Node
resource "aws_instance" "control_plane" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.k3s_sg.id]
  key_name               = aws_key_pair.deployer.key_name

  tags = {
    Name = "k3s-control-plane"
    Role = "control-plane"
  }
}

# 2x Worker Nodes
resource "aws_instance" "workers" {
  count                  = var.worker_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.k3s_sg.id]
  key_name               = aws_key_pair.deployer.key_name

  tags = {
    Name = "k3s-worker-${count.index + 1}"
    Role = "worker"
  }
}

# Outputs
output "control_plane_ip" {
  value       = aws_instance.control_plane.public_ip
  description = "Public IP of K3s Control Plane"
}

output "worker_ips" {
  value       = aws_instance.workers[*].public_ip
  description = "Public IPs of K3s Workers"
}
