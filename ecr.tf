resource "aws_ecr_repository" "backend" {
  name         = "bootcamp1-app/backend"
  force_delete = true
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = {
    Cluster = var.cluster_name
  }
}

resource "aws_ecr_repository" "frontend" {
  name         = "bootcamp1-app/frontend"
  force_delete = true
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = {
    Cluster = var.cluster_name
  }
}

output "ecr_backend_url" { value = aws_ecr_repository.backend.repository_url }
output "ecr_frontend_url" { value = aws_ecr_repository.frontend.repository_url }
