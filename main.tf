terraform {
  cloud {

    organization = "CLOUD_27"

    workspaces {
      name = "tf_web_server"
    }
  }
}

##Defines the cloud provider (AWS) and its region where resources will be deployed.
provider "aws" {
  region = "us-east-1" # Specify the AWS region for your resources
}

# Define common variables
##variable: Defines input variables for the Terraform configuration.
##prefix: A string used as a prefix for naming resources.
variable "prefix" {
  description = "Base prefix for resource names"
  type        = string
  default     = "my-web-server"
}

##variable: Defines input variables for the Terraform configuration.
##instance_count: Number of EC2 instances to create.
variable "instance_count" {
  description = "Total number of EC2 instances to create"
  type        = number
  default     = 3
}

##Defines local values that can be used within the configuration.
##instance_names: Creates a list of names for the EC2 instances based on the prefix and count.
##vpc_name, subnet_name, sg_name: Names for the VPC, subnet, and security group.
locals {
  instance_names = [for idx in range(var.instance_count) : "${var.prefix}-instance-${idx + 1}"]
  vpc_name       = "${var.prefix}-vpc"
  subnet_name    = "${var.prefix}-subnet"
  sg_name        = "${var.prefix}-sg"
}

# Define SSH key pair
##aws_key_pair: Manages an SSH key pair for accessing EC2 instances.
##key_name: The name for the key pair.
##public_key: Path to the public key file used for SSH access.
resource "aws_key_pair" "deployer" {
  key_name   = "deployer-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

# Set up VPC and networking components
##aws_vpc: Defines a Virtual Private Cloud (VPC) with a CIDR block of 10.0.0.0/16.
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16" # Updated CIDR block for VPC
  tags = {
    Name = local.vpc_name
  }
}

##aws_internet_gateway: Creates an internet gateway to allow external access.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

##aws_subnet: Defines a subnet within the VPC with a CIDR block of 10.0.1.0/24.
resource "aws_subnet" "main" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24" # Updated CIDR block for subnet
  tags = {
    Name = local.subnet_name
  }
}

##aws_route_table: Creates a route table with a route to the internet.
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

##aws_route_table_association: Associates the subnet with the route table to ensure internet traffic can flow through the subnet.
resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}

# Define the security group
##aws_security_group: Creates a security group with rules for inbound and outbound traffic.
resource "aws_security_group" "web" {
  vpc_id = aws_vpc.main.id

  ##ingress: Rules allowing SSH (port 22), HTTP (port 80), and HTTPS (port 443) traffic.
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow SSH access"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP access"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS access"
  }

  ##egress: Allows all outbound traffic.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = local.sg_name
  }
}

# Create EC2 instances
##aws_instance: Creates EC2 instances based on the count specified.
resource "aws_instance" "server" {
  count                  = var.instance_count
  ami                    = "ami-0182f373e66f89c85" # Replace with your AMI ID
  instance_type          = "t2.micro"
  key_name               = aws_key_pair.deployer.key_name
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = <<-EOF
                     #!/bin/bash
                     sudo yum update -y
                     sudo yum install -y httpd
                     sudo systemctl start httpd
                     sudo systemctl enable httpd
                     echo "<h1>Hello from ${local.instance_names[count.index]}</h1>" | sudo tee /var/www/html/index.html
  EOF

  ##Assigns a unique name to each instance based on local.instance_names.
  tags = {
    Name = local.instance_names[count.index]
  }

  ##Ensures that the instance is created before destroying the old one.
  lifecycle {
    create_before_destroy = true
  }
}

# Allocate Elastic IPs for each instance
##Allocates an Elastic IP and associates it with each EC2 instance.
resource "aws_eip" "instance_ip" {
  count    = var.instance_count
  instance = aws_instance.server[count.index].id
  domain   = "vpc"
}

# Output the public IP addresses of the instances
output "instance_public_ips" {
  value = { for idx in range(var.instance_count) : local.instance_names[idx] => aws_eip.instance_ip[idx].public_ip }
}
