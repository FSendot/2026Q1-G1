output "cluster_name" {
  description = "Nombre del ECS Cluster que ejecuta el servicio."
  value       = aws_ecs_cluster.main.name
}

output "cluster_arn" {
  description = "ARN del ECS Cluster que ejecuta el servicio."
  value       = aws_ecs_cluster.main.arn
}

output "service_name" {
  description = "Nombre del ECS Service que mantiene corriendo las tasks Fargate."
  value       = aws_ecs_service.app.name
}

output "task_definition_arn" {
  description = "ARN del task definition activo."
  value       = aws_ecs_task_definition.app.arn
}

output "task_security_group_id" {
  description = "ID del Security Group asignado a las tasks Fargate."
  value       = aws_security_group.task.id
}

output "ecr_repository_url" {
  description = "URL del repositorio ECR que aloja la imagen de la aplicación."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_arn" {
  description = "ARN del repositorio ECR."
  value       = aws_ecr_repository.app.arn
}

output "log_group_name" {
  description = "Nombre del CloudWatch Log Group donde el contenedor publica sus logs."
  value       = aws_cloudwatch_log_group.app.name
}

output "autoscaling_target_resource_id" {
  description = "Resource ID registrado en Application Auto Scaling para el ECS Service."
  value       = aws_appautoscaling_target.ecs.resource_id
}
