# bootstrap-webserver.tf
# Deploys a public web server on AWS from absolute zero in < 60 seconds
# -pk

# HOW TO USE (copy-paste these exact 3 commands):
#   1. Save this file as: bootstrap-webserver.tf
#   2. Open a terminal in the folder and run:
#        terraform init
#        terraform apply -auto-approve
#   3. Wait ~45 seconds → open the URL shown in "website_url"
#      Immediately copy the private key (only shown once!)

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws    = { source = "hashicorp/aws",    version = "~> 5.70" }
    tls    = { source = "hashicorp/tls",    version = "~> 4.0"  }
    random = { source = "hashicorp/random", version = "~> 3.6"  }
  }
}

provider "aws" {
  region = "us-east-1"   # change only if you prefer another region
}

resource "random_pet" "prefix" {
  length = 2
}

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "generated" {
  key_name   = random_pet.prefix.id
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = random_pet.prefix.id }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "web" {
  name   = random_pet.prefix.id
  vpc_id = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = random_pet.prefix.id }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = aws_key_pair.generated.key_name

  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y httpd
    systemctl enable --now httpd
    instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    cat > /var/www/html/index.html <<'EOM'
    <!DOCTYPE html>
    <html lang="en">
    <body style="font-family:Arial,sans-serif;text-align:center;margin-top:15%">
      <h1>Terraform Bootstrap Successful</h1>
      <p><strong>Instance ID:</strong> $instance_id<br>
         <strong>Deployed:</strong> $(date)<br>
         <strong>Source:</strong> bootstrap-webserver.tf</p>
    </body>
    </html>
    EOM
  EOF

  tags = { Name = random_pet.prefix.id }
}

resource "aws_eip" "web" {
  instance = aws_instance.web.id
  domain   = "vpc"
}

output "website_url" {
  description = "Open this URL in your browser now"
  value       = "http://${aws_eip.web.public_ip}"
}

output "ssh_command" {
  description = "Run after saving the private key"
  value       = "ssh -i ${random_pet.prefix.id}.pem ec2-user@${aws_eip.web.public_ip}"
}

output "private_key_pem" {
  description = "SAVE THIS PRIVATE KEY IMMEDIATELY → ${random_pet.prefix.id}.pem (chmod 400 it)"
  value       = tls_private_key.ssh.private_key_pem
  sensitive   = true
}
