# Empaquetado de handlers Lambda en app/; los módulos solo reciben rutas a los .zip generados.

resource "random_password" "db" {
  length  = 20
  special = false
}

resource "aws_lambda_layer_version" "psycopg2" {
  filename                 = "layers/psycopg2/psycopg2-layer.zip"
  layer_name               = format("%s-psycopg2", local.project)
  source_code_hash         = filebase64sha256("layers/psycopg2/psycopg2-layer.zip")
  compatible_runtimes      = ["python3.12"]
  compatible_architectures = ["x86_64"]

  lifecycle {
    create_before_destroy = true
  }
}

data "archive_file" "api_lambda" {
  type        = "zip"
  source_file = "${path.module}/app/api/handler.py"
  output_path = "${path.module}/app/api/build/api.zip"
}

data "archive_file" "notification_summarizer" {
  type        = "zip"
  source_file = "${path.module}/app/notification/summarizer/handler.py"
  output_path = "${path.module}/app/notification/build/summarizer.zip"
}
