# Provider Configuration
provider "aws" {
  region = "us-east-1"
}

# Terraform State Storage in S3
terraform {
  backend "s3" {
    bucket = "elo-terraform-state"
    key    = "state/terraform.tfstate"
    region = "us-east-1"
  }
}

# Create a VPC
resource "aws_vpc" "elo_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "elo-vpc"
  }
}

# Create Public Subnets
resource "aws_subnet" "public_subnet_1" {
  vpc_id            = aws_vpc.elo_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
  tags = {
    Name = "public-subnet-1"
  }
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id            = aws_vpc.elo_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
  tags = {
    Name = "public-subnet-2"
  }
}

# Create an Internet Gateway
resource "aws_internet_gateway" "elo_igw" {
  vpc_id = aws_vpc.elo_vpc.id
  tags = {
    Name = "elo-igw"
  }
}

# Create a Route Table for Public Subnets
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.elo_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.elo_igw.id
  }
  tags = {
    Name = "public-route-table"
  }
}

# Associate Public Subnets with the Route Table
resource "aws_route_table_association" "public_subnet_1_association" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "public_subnet_2_association" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public_route_table.id
}

# Create an EKS Cluster
resource "aws_eks_cluster" "elo_cluster" {
  name     = "elo-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn
  vpc_config {
    subnet_ids = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
  }
  tags = {
    Name = "elo-cluster"
  }
}

# IAM Role for EKS Cluster
resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

# Attach Policies to EKS Cluster Role
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_service_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# Create an RDS Database
resource "aws_db_instance" "elo_rds" {
  allocated_storage    = 20
  storage_type         = "gp2"
  engine               = "postgres"
  engine_version       = "17" # Updated to a valid version
  instance_class       = "db.t3.micro"
  db_name              = "elodb"
  username             = "eloadmin"
  password             = "securepassword"
  skip_final_snapshot  = true
  publicly_accessible  = false
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name = aws_db_subnet_group.elo_db_subnet_group.name
  tags = {
    Name = "elo-rds"
  }
}

# Create a DB Subnet Group
resource "aws_db_subnet_group" "elo_db_subnet_group" {
  name       = "elo-db-subnet-group"
  subnet_ids = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
  tags = {
    Name = "elo-db-subnet-group"
  }
}

# Security Group for RDS
resource "aws_security_group" "rds_sg" {
  vpc_id = aws_vpc.elo_vpc.id
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "rds-sg"
  }
}

# Create an API Gateway
resource "aws_api_gateway_rest_api" "elo_api" {
  name        = "elo-api"
  description = "API Gateway for Elo"
  endpoint_configuration {
    types = ["REGIONAL"]
  }
  tags = {
    Name = "elo-api"
  }
}

# Create the S3 bucket
resource "aws_s3_bucket" "elo_bucket" {
  bucket = "elo-static-assets"
  tags = {
    Name = "elo-bucket"
  }
}

# Enable server-side encryption for the S3 bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "elo_bucket_encryption" {
  bucket = aws_s3_bucket.elo_bucket.bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Add CloudTrail Bucket Policy
resource "aws_s3_bucket_policy" "cloudtrail_bucket_policy" {
  bucket = aws_s3_bucket.elo_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.elo_bucket.arn}/AWSLogs/535002849489/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
         }
      },
      {
        Sid    = "AllowCloudTrailRead",
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.elo_bucket.arn
      },
      {
        Sid    = "AllowCloudTrailList"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.elo_bucket.arn
      }
    ]
  })
}

# Enable CloudTrail for Auditing
resource "aws_cloudtrail" "elo_trail" {
  name           = "elo-trail"
  s3_bucket_name = aws_s3_bucket.elo_bucket.id
  enable_logging = true
  tags = {
# Enable CloudTrail for Auditing
resource "aws_cloudtrail" "elo_trail" {
# Enable CloudTrail for Auditing
  GNU nano 5.8                                                                   main.tf                                                                              
  s3_bucket_name = aws_s3_bucket.elo_bucket.id
  enable_logging = true
  tags = {
    Name = "elo-trail"
  }
}

# Outputs
output "vpc_id" {
  value = aws_vpc.elo_vpc.id
}

output "eks_cluster_name" {
  value = aws_eks_cluster.elo_cluster.name
}

output "rds_endpoint" {
  value = aws_db_instance.elo_rds.endpoint
}

output "api_gateway_id" {
  value = aws_api_gateway_rest_api.elo_api.id
}

