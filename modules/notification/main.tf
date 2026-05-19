module "topic" {
  source = "./topic"

  project       = var.project
  principal_arn = var.principal_arn
  tags          = var.tags
}

module "summary_queue" {
  source = "./summary_queue"

  project       = var.project
  principal_arn = var.principal_arn
  tags          = var.tags
}

module "summarizer" {
  source = "./summarizer"

  project                         = var.project
  principal_arn                   = var.principal_arn
  vpc_id                          = var.vpc_id
  private_subnet_ids              = var.private_subnet_ids
  endpoint_security_group_id      = var.endpoint_security_group_id
  source_file                     = var.summarizer_source_file
  fraud_alert_queue_url           = module.summary_queue.queue_url
  summary_topic_arn               = module.topic.topic_arn
  summary_interval_minutes        = var.summary_interval_minutes
  summarizer_max_messages_per_run = var.summarizer_max_messages_per_run
  log_retention_days              = var.log_retention_days
  tags                            = var.tags
}
