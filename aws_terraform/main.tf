provider "aws" {
  region = "us-west-1"
}

# Retrieve the default VPC
data "aws_vpc" "default" {
  default = true
}

# Retrieve the subnets associated with the default VPC
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Reference the existing ECR repository
data "aws_ecr_repository" "my_ecr" {
  name = "my-flask-app"
}

# Create IAM role for ECS tasks to interact with ECR
resource "aws_iam_role" "ecs_task_role" {
  name = "ecs-task-role-${random_string.suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Random string for unique IAM role naming
resource "random_string" "suffix" {
  length  = 8
  special = false
}

# Create IAM policy for admin rights (full access to all AWS resources)
resource "aws_iam_policy" "ecs_admin_policy" {
  name        = "ecs-admin-policy"
  description = "Admin access policy for ECS task role"
  policy      = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "*"
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# Attach admin policy to the ECS task role
resource "aws_iam_role_policy_attachment" "ecs_task_role_admin" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.ecs_admin_policy.arn
}

# Attach policy to the ECS task role for ECR access with admin rights
resource "aws_iam_role_policy" "ecs_task_policy" {
  name   = "ecs-task-policy"
  role   = aws_iam_role.ecs_task_role.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action   = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:logs:us-west-1:123456789012:log-group:/ecs/flask-app-logs:*"
      }
    ]
  })
}

# Define the ECS Cluster
resource "aws_ecs_cluster" "flask_app_cluster" {
  name = "flask-app-cluster"
}

# Create a new security group (allow HTTP traffic on port 5000)
resource "aws_security_group" "ecs_sg" {
  name        = "flask-app-sg-new"
  description = "Allow HTTP traffic on port 5000"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Allow all IPs to access port 5000 (change for more restriction)
  }

  egress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Define the ECS task definition using the Docker image from the existing ECR repository
resource "aws_ecs_task_definition" "flask_task_definition" {
  family                   = "flask-app-task"
  execution_role_arn       = aws_iam_role.ecs_task_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([{
    name      = "flask-app-container"
    image     = "${data.aws_ecr_repository.my_ecr.repository_url}:latest"
    essential = true
    portMappings = [
      {
        containerPort = 5000
        hostPort      = 5000
        protocol      = "tcp"
      }
    ]
  }])
}

# Define the ECS service to run the Flask app task in the ECS cluster
resource "aws_ecs_service" "flask_ecs_service" {
  name            = "flask-app-service"
  cluster         = aws_ecs_cluster.flask_app_cluster.id
  task_definition = aws_ecs_task_definition.flask_task_definition.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }
}

# CloudWatch Log Group for monitoring ECS task logs
resource "aws_cloudwatch_log_group" "flask_log_group" {
  name = "/ecs/flask-app-logs"
}

# CloudWatch Metric Alarm to monitor log events (threshold can be adjusted)
resource "aws_cloudwatch_metric_alarm" "flask_log_alarm" {
  alarm_name                = "flask-log-alarm"
  comparison_operator       = "GreaterThanThreshold"
  evaluation_periods        = "1"
  metric_name               = "IncomingLogEvents"
  namespace                 = "AWS/Logs"
  period                    = "60"
  statistic                 = "Sum"
  threshold                 = "10"
  alarm_description         = "Trigger alarm when log is written more than 10 times in a minute"
  insufficient_data_actions = []

  dimensions = {
    LogGroupName = aws_cloudwatch_log_group.flask_log_group.name
  }

  actions_enabled = true
  alarm_actions   = [data.aws_sns_topic.my_sns.arn]
}

# Retrieve the SNS Topic ARN for CloudWatch Alarms
data "aws_sns_topic" "my_sns" {
  name = "MySNS"
}

# Optional: Output ECS cluster and service details
output "ecs_cluster_name" {
  value = aws_ecs_cluster.flask_app_cluster.name
}

output "ecs_service_name" {
  value = aws_ecs_service.flask_ecs_service.name
}
