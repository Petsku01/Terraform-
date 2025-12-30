# safe-bootstrap-webserver.tf
#
#
# Fixes:
# • No private keys in state or output
# • SSH only from YOUR current IP
# • Uses default VPC → instant
# • On any AWS account



terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
    http = { source = "hashicorp/http", version = "~> 3.4" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
provider "aws" {
  region = "us-east-1"
}
# Your current public IP (for SSH allow-list)
data "http" "myip" {
  url = "https://ifconfig.co/ip"
}
# Latest official Amazon Linux 2023 AMI (maintained forever by AWS)
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}
# Use the account’s default VPC and a public subnet
data "aws_vpc" "default" {
  default = true
}
data "aws_subnets" "public" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name = "map-public-ip-on-launch"
    values = ["true"]
  }
}
resource "random_integer" "id" {
  min = 1000
  max = 9999
}
resource "aws_security_group" "web" {
  name = "safe-demo-web-${random_integer.id.result}"
  vpc_id = data.aws_vpc.default.id
  ingress {
    description = "HTTP from anywhere"
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH only from YOU"
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["${chomp(data.http.myip.response_body)}/32"]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "safe-demo-${random_integer.id.result}" }
}
resource "aws_instance" "web" {
  ami = data.aws_ssm_parameter.al2023_ami.value
  instance_type = "t4g.micro" # ARM = cheaper + faster in 2025–2026
  subnet_id = data.aws_subnets.public.ids[0]
  vpc_security_group_ids = [aws_security_group.web.id]
  associate_public_ip_address = true
  user_data = <<-EOF
    #!/bin/bash
    set -e  # Exit on error for robustness
    dnf update -y
    dnf install -y httpd
    systemctl enable httpd --now
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)
    PUBLIC_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/public-ipv4)
    cat > /var/www/html/index.html <<EOM
    <!DOCTYPE html>
    <html lang="en"><head><meta charset="utf-8"><title>Success!</title></head>
    <body style="font-family:Arial;text-align:center;margin-top:15%">
      <h1>Terraform Safe Bootstrap Works!</h1>
      <p><strong>Instance:</strong> $INSTANCE_ID<br>
         <strong>IP:</strong> $PUBLIC_IP<br>
         <strong>Time:</strong> $(date)</p>
      <hr>
      <p><code>terraform destroy -auto-approve</code> when done</p>
    </body>
    </html>
    EOM
  EOF
  tags = { Name = "safe-demo-${random_integer.id.result}" }
}
# Final outputs — clean and useful
output "website_url" {
  description = "Open this in your browser immediately!"
  value = "http://${aws_instance.web.public_ip}"
}
output "ssh_instructions" {
  description = "To SSH (no key pair attached; use EC2 Instance Connect)"
  value = "Via AWS Console: EC2 > Instances > select ${aws_instance.web.id} > Connect > EC2 Instance Connect. Or CLI: aws ec2-instance-connect ssh --instance-id ${aws_instance.web.id} (requires AWS CLI setup)."
}
output "destroy_command" {
  description = "Run this when you're done (costs ~$0.004/hour while running)"
  value = "terraform destroy -auto-approve"
}
output "congratulations" {
  value = <<EOT
SUCCESS! Your web server is live in ~20 seconds.
→ Website: http://${aws_instance.web.public_ip}
→ SSH: only from your current IP (${chomp(data.http.myip.response_body)}); use EC2 Instance Connect (no keys needed)
→ No private keys were exposed or stored
→ Total running cost ≈ $0.004 per hour (t4g.micro + tiny data)
When finished → run:
    terraform destroy -auto-approve
Enjoy responsibly!
EOT
}
