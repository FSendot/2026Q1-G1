# Empaquetado de handlers Lambda en app/; los módulos solo reciben rutas a los .zip generados.

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
