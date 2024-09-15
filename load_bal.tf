terraform {
  cloud {

    organization = "CLOUD_27"

    workspaces {
      name = "tf_web_server"
    }
  }
}

#Define which cloud provider and region to use
provider "aws" {
  region = "us-east-1" # Specify the AWS region
}

# Variables section for setting up configurable parameters

# Prefix for naming resources to maintain consistency and avoid collisions
variable "prefix" {
  description = "Base prefix for resource names"
  type        = string
  default     = "my-web-server"
}

# Define how many EC2 instances to launch
variable "instance_count" {
  description = "Number of EC2 instances"
  type        = number
  default     = 3
}

# Local values to simplify naming and reuse them across different resources
locals {
  instance_names = [for idx in range(var.instance_count) : "${var.prefix}-instance-${idx + 1}"]
  vpc_name       = "${var.prefix}-vpc"
  sg_name        = "${var.prefix}-sg"
  lb_sg_name     = "${var.prefix}-lb-sg"
}

#AWS Key Pair for SSH access to the EC2 instances
resource "aws_key_pair" "deployer" {
  key_name   = "deployer-key"
  public_key = file("~/.ssh/id_rsa.pub") # Path to your SSH public key
}

#Virtual Private Cloud (VPC) to host all your AWS resources
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16" # CIDR block for the VPC
  tags = {
    Name = local.vpc_name # Tag the VPC with the name
  }
}

#Attach an Internet Gateway to the VPC so that instances can access the internet
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id # Attach the Internet Gateway to the created VPC
}

#Subnet 1 in a different availability zone, for Load Balancer (NLB) redundancy
resource "aws_subnet" "subnet_1" {
  vpc_id            = aws_vpc.main.id # VPC ID where this subnet resides
  cidr_block        = "10.0.1.0/24"   # Subnet CIDR
  availability_zone = "us-east-1a"    # Specific availability zone (AZ)
  tags = {
    Name = "${var.prefix}-subnet-1"
  }
}

#Subnet 2 in a different availability zone, for Load Balancer (NLB) redundancy
resource "aws_subnet" "subnet_2" {
  vpc_id            = aws_vpc.main.id # VPC ID where this subnet resides
  cidr_block        = "10.0.2.0/24"   # Subnet CIDR
  availability_zone = "us-east-1b"    # Another AZ for redundancy
  tags = {
    Name = "${var.prefix}-subnet-2"
  }
}

#Route table that allows outbound internet traffic from the VPC
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"                  # Route to all IP addresses
    gateway_id = aws_internet_gateway.main.id # Traffic routed through the Internet Gateway
  }
}

#Associate the route table with subnet 1
resource "aws_route_table_association" "subnet_1" {
  subnet_id      = aws_subnet.subnet_1.id
  route_table_id = aws_route_table.main.id
}

#Associate the route table with subnet 2
resource "aws_route_table_association" "subnet_2" {
  subnet_id      = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.main.id
}

#Create a security group for the EC2 instances, allowing SSH, HTTP, and HTTPS access
resource "aws_security_group" "web" {
  vpc_id = aws_vpc.main.id

  #Allow SSH (port 22) from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow SSH access"
  }

  #Allow HTTP (port 80) from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP access"
  }

  #Allow HTTPS (port 443) from anywhere
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS access"
  }

  #Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = local.sg_name # Tag the security group with a name
  }
}

#Launch EC2 instances using the provided AMI, key pair, and security group
resource "aws_instance" "server" {
  count                  = var.instance_count             #Create multiple instances based on instance_count
  ami                    = "ami-0182f373e66f89c85"        #Amazon Machine Image (AMI) ID
  instance_type          = "t2.micro"                     #Instance size/type
  key_name               = aws_key_pair.deployer.key_name #Key pair for SSH access
  subnet_id              = aws_subnet.subnet_1.id         #Place the instances in the first subnet for simplicity
  vpc_security_group_ids = [aws_security_group.web.id]    #Attach security group

  #User data script to install Apache and display a basic webpage
  user_data = <<-EOF
    #!/bin/bash
    sudo yum update -y
    sudo yum install -y httpd
    sudo systemctl start httpd
    sudo systemctl enable httpd
    echo "<h1>Hello from ${local.instance_names[count.index]}</h1>" | sudo tee /var/www/html/index.html
  EOF

  #Assign names to each instance
  tags = {
    Name = local.instance_names[count.index]
  }

  #Ensure instances are replaced safely (created before being destroyed)
  lifecycle {
    create_before_destroy = true
  }
}

#Create a security group for the Network Load Balancer (NLB)
resource "aws_security_group" "lb" {
  vpc_id = aws_vpc.main.id

  #Allow HTTP traffic (port 80) from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP traffic"
  }

  #Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = local.lb_sg_name
  }
}

#Create a Network Load Balancer (NLB) to distribute traffic across EC2 instances
resource "aws_lb" "nlb" {
  name               = "${var.prefix}-nlb"
  internal           = false                                            # This NLB is public-facing
  load_balancer_type = "network"                                        # NLB type
  subnets            = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id] # Subnets for NLB
}

#Create Elastic IPs for the NLB for static IP addressing
resource "aws_eip" "nlb_ip_1" {
  # No need for 'vpc' argument; it’s deprecated
  tags = {
    Name = "${var.prefix}-eip-1"
  }
}

resource "aws_eip" "nlb_ip_2" {
  tags = {
    Name = "${var.prefix}-eip-2"
  }
}

#Forward incoming traffic to the target group using TCP
resource "aws_lb_listener" "web" {
  load_balancer_arn = aws_lb.nlb.arn # NLB ARN
  port              = 80             # Listen on HTTP port 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn # Forward traffic to target group
  }
}

#Target group for the EC2 instances, handling HTTP (port 80) traffic
resource "aws_lb_target_group" "web" {
  name     = "${var.prefix}-tg"
  port     = 80
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  #Health check for the target instances
  health_check {
    protocol            = "TCP"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 3
    unhealthy_threshold = 2
  }
}

#Attach the EC2 instances to the NLB target group
resource "aws_lb_target_group_attachment" "web" {
  count            = var.instance_count                  # Attach all instances
  target_group_arn = aws_lb_target_group.web.arn         # Target group ARN
  target_id        = aws_instance.server[count.index].id # Instance IDs to attach
  port             = 80                                  # HTTP port
}

#Output the Elastic IPs of the NLB for reference
output "nlb_ip_1" {
  value = aws_eip.nlb_ip_1.public_ip
}

output "nlb_ip_2" {
  value = aws_eip.nlb_ip_2.public_ip
}
